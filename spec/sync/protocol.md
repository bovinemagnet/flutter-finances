# Sync protocol, version 1

The client is the primary store. Every user action is saved together with a
command in a local outbox in one SQLite transaction (SYNC 01). The server
validates commands, commits canonical state and exposes an ordered change
feed. All JSON uses camelCase. Money is integer minor units in the
workspace currency; dates are `YYYY-MM-DD`; instants are ISO 8601 UTC.

## Command envelope

```json
{
  "commandId": "uuid", "workspaceId": "uuid", "deviceId": "uuid",
  "type": "journal.post | journal.correct | entity.upsert | entity.delete",
  "entityType": "journal | account | category | ...",
  "entityId": "uuid", "baseRevision": 0, "schemaVersion": 1,
  "payload": {}
}
```

`POST /v1/sync/commands` accepts `{"commands": [...]}` (at most 500) and
returns `{"results": [...]}` in the same order. Each command is committed in
its own database transaction together with its idempotency record and change
records (SYNC 02).

Result:

```json
{
  "commandId": "uuid",
  "status": "applied | previously_applied | conflict | validation_failed | permission_denied",
  "revision": 3, "cursor": "opaque",
  "errors": ["UNBALANCED"],
  "conflict": {"serverRevision": 4, "serverState": {}, "fields": ["amountMinor"]}
}
```

Replaying a `commandId` returns the stored original result with status
`previously_applied` and never applies twice (A09). A `commandId` reused with
a different payload hash is `validation_failed` with `IDEMPOTENCY_KEY_REUSED`.

## Revisions and conflicts

Each entity has an integer `revision`, starting at 1 on creation and
incremented on every accepted change. `baseRevision` is the revision the
client last saw (0 for a new entity).

- `journal.post` payload `{"journal": Journal}` creates a journal, or replaces one whose stored status is
  `draft` or `pending`. Replacing requires `baseRevision` to equal the stored
  revision; otherwise `conflict`. A posted or reversed journal can only be
  changed with `journal.correct`.
- `journal.correct` payload `{"originalId", "reversal": Journal,
  "replacement": Journal | null}`. `entityId` is the original; its stored
  revision must equal `baseRevision`, otherwise `conflict` (A10: two devices
  correcting the same amount produce one accepted correction and one
  conflict). The original's status becomes `reversed` atomically with
  inserting the reversal and replacement.
- `entity.upsert` payload `{"fields": {...}}` with only the changed fields.
  The server keeps a revision per field. A field changed on the server after
  `baseRevision` with a different value is a conflict and nothing is
  applied; otherwise fields merge (SYNC 03). Never last write wins.
- `entity.delete` writes a tombstone. Deleting a posted journal is rejected
  (`POSTED_JOURNAL_IMMUTABLE`); void it with `journal.correct` and a null
  replacement.

## Journal validation (server)

Postings validate with the rules in `spec/fixtures/README.md`. Additionally:
`currency` equals the workspace currency (`CURRENCY_MISMATCH`), every posting
account is an existing, non-deleted account or category entity in the
workspace or a `system:` account (`UNKNOWN_LEDGER_ACCOUNT`), the status is
not `reversed` (`INVALID_STATUS`), and reversal journals negate their
original exactly (`REVERSAL_MISMATCH`).

## Change feed

`GET /v1/sync/changes?cursor=<opaque>&limit=500` returns
`{"changes": [...], "cursor": "opaque", "hasMore": bool}`; each change is
`{"entityType", "entityId", "revision", "op": "upsert | delete", "data": {}}`
where `data` is the full current entity. An empty cursor starts from the
beginning. A cursor older than the tombstone horizon (90 days, SYNC 06)
returns HTTP 410 with `{"error": "CURSOR_EXPIRED"}`; the client then pages
`GET /v1/sync/snapshot?after=<entityKey>&limit=500` and rebases its pending
commands (A15). A snapshot page is `{"changes": [...], "after": "entityKey",
"hasMore": bool, "cursor": "opaque"}`: `changes` uses the change feed item
shape for every live entity ordered by entity key (`entityType/entityId`),
`after` is the key to pass for the next page, and `cursor` is the change feed
position captured when the first page was produced, from which the client
resumes `GET /v1/sync/changes` after the last page. Pending commands for entities deleted in the meantime are surfaced for
review, never applied automatically.

## Receipt documents (SYNC 05)

1. `POST /v1/receipts/upload-intents` with
   `{"receiptId", "assetId", "kind": "source | derivative", "contentType",
   "sizeBytes", "sha256"}` returns `{"uploadUrl", "headers", "expiresAt"}` for
   a short-lived presigned PUT. Re-requesting an intent for the same
   `assetId` and checksum returns a fresh URL for the same object.
2. The client PUTs the bytes, then `POST /v1/receipts/{receiptId}/complete`
   with `{"assetId"}`. The server verifies ownership, size, checksum and
   content type by magic bytes, then marks the asset `quarantined` until the
   scan job marks it `available` or `rejected`. Completing twice is a no-op;
   it never creates a second receipt.
3. `GET /v1/receipts/{receiptId}/assets/{assetId}/download` returns
   `{"downloadUrl", "expiresAt"}`, a short-lived presigned GET, only for
   members of the owning workspace (A17). While the asset is still uploading
   or quarantined it returns HTTP 409 `{"error": "ASSET_NOT_AVAILABLE"}`.

## Entity JSON

Journal:

```json
{
  "id": "uuid", "type": "expense", "status": "posted",
  "effectiveDate": "2026-07-01", "enteredAt": "2026-07-01T02:03:04Z",
  "currency": "AUD",
  "postings": [{"account": "groceries", "amountMinor": 1000},
               {"account": "bank", "amountMinor": -1000}],
  "accountId": "bank", "counterAccountId": null, "amountMinor": 1000,
  "payee": "Grocer", "notes": null, "tags": [],
  "refundOf": null, "reversalOf": null, "replaces": null
}
```

Account: `{"id", "name", "type", "includeInBudget", "includeInForecast",
"includeInNetWorth", "archived", "dataSource", "lastReconciledOn"}`.
Category: `{"id", "name", "kind", "parentId", "archived"}`. Other entity
types are opaque JSON objects to the server and are defined by
`finance_core` codecs.
