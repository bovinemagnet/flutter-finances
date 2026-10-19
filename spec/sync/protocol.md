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
The hash covers `type`, `entityType`, `entityId` and `payload` only, because
clients rewrite `baseRevision`, `workspaceId` and `deviceId` of unsent
commands (rebase, bootstrap) while keeping the `commandId`. Only applied
commands are recorded: a `conflict` or `validation_failed` command changed
nothing and is evaluated again if it is retried.

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

## Server behaviour

Decisions the server makes where the sections above are silent.

**Authentication and scope.** Every call carries an OIDC access token
(`Authorization: Bearer`); users are keyed by the token's `sub`. The
`/v1/sync/*` endpoints require `X-Device-Id`, a registered, unrevoked device
of the caller, which also selects the workspace (`400 DEVICE_REQUIRED`,
`403 DEVICE_NOT_AUTHORISED`, `403 DEVICE_REVOKED`). Other workspace endpoints
take `X-Workspace-Id`, or fall back to the workspace of `X-Device-Id`. A
workspace the caller is not a member of is `404 WORKSPACE_NOT_FOUND`;
another workspace's receipt, asset, job or export is `404`, never `403`, so
an identifier reveals nothing (A17). A command whose `workspaceId` or
`deviceId` differs from the calling device's is `permission_denied`.

**Setup.** `POST /v1/workspaces` `{"id"?, "name", "currency", "timezone"}`
creates a workspace owned by the caller (`id` may be generated offline; a
deleted workspace's id is refused with `409 WORKSPACE_DELETED`, so a restore
always creates a new workspace, DATA 03). `GET /v1/workspaces` lists the
caller's workspaces and `GET /v1/workspaces/{id}` returns the bootstrap
settings (currency and exponent, timezone, `schemaVersion`,
`tombstoneHorizonDays`, `maxCommandsPerBatch`, `serverTime`).
`POST /v1/devices` `{"deviceId", "workspaceId", "name", "platform"}`
registers a device (repeating it is harmless); `DELETE /v1/devices/{id}`
revokes it for good (its owner or a workspace owner).

**Absent and deleted entities.** A command against a tombstone is a
`conflict` with `errors: ["ENTITY_DELETED"]` and `serverState: null`; one
with `baseRevision > 0` for an entity the server never had is a `conflict`
with `errors: ["ENTITY_NOT_FOUND"]`. This includes deleting an entity twice.
Tombstoned rows are kept without data after the horizon, so no pending
command can resurrect them (A15).

**Journals.** Journals change only through `journal.post` and
`journal.correct`; `entity.upsert` of a journal is `USE_JOURNAL_COMMANDS`
(clients annotate payee, notes and tags through a `journalAnnotation`
entity). A reversal must be type `reversal`, status `posted`, dated on the
original's effective date, with `reversalOf` set and postings that cancel
the original per account (`REVERSAL_MISMATCH`). A replacement's `replaces`
must be the original's id (`REPLACEMENT_MISMATCH`). Correcting a reversed
original is a `conflict`; a draft or pending one is `INVALID_STATUS`. Only
the known `system:` accounts (`opening-equity`, `balance-adjustments`,
`transfer-clearing`, `reimbursement-receivable`) are accepted. An account or
category used by any posting cannot be deleted (`ENTITY_IN_USE`); archive it
instead. The database also enforces balanced journals and immutable posted
journals; a command it rejects is `LEDGER_CONSTRAINT`.

**Other validation codes.** `INVALID_COMMAND` (malformed envelope or
unknown type), `UNSUPPORTED_SCHEMA_VERSION`, `INVALID_JOURNAL` (malformed
journal JSON), `ENTITY_ID_MISMATCH`, `ENTITY_TYPE_MISMATCH`, `INVALID_TYPE`
(a reversal posted directly), `DUPLICATE_ENTITY`, and for accounts and
categories `MISSING_FIELD` (name and type or kind on creation),
`INVALID_FIELD` and `IMMUTABLE_FIELD` (account type, category kind). Every
other entity type, such as `receipt`, `documentAsset` and
`journalAnnotation`, is opaque JSON with field-level merge. Unknown
envelope and entity fields are ignored and preserved (NFR 12).

**Feed and snapshot.** A delete change carries `data: {"id"}`. `limit` is
capped at 500. A non-empty cursor expires (410) when it was issued more than
the horizon ago, or when a tombstone purge that ran after it was issued
removed a delete beyond its position; an empty cursor never expires, and
the compacted log still holds the latest change of every live entity.
Every snapshot page returns the feed position when it was produced; the
client keeps the first page's.

**Receipts.** An intent needs a live `receipt` entity in the workspace
(`404 RECEIPT_NOT_FOUND`); the first intent binds the receipt to that
workspace. Accepted types are those `content.sniff` recognises (JPEG, PNG,
HEIC, HEIF, PDF; `400 UNSUPPORTED_CONTENT_TYPE`), up to 25 MiB
(`400 TOO_LARGE`), with a lower-case hex `sha256` (`400 INVALID_CHECKSUM`).
Uploads go to a staging key; completion copies verified bytes to the
asset's permanent key, so a late or repeated upload cannot replace them.
Completion answers `200 {"status": "quarantined" | "available" |
"rejected"}`, `404 UNKNOWN_ASSET`, `409 OBJECT_MISSING` (nothing uploaded),
or `422 CHECKSUM_MISMATCH` (size or checksum) and `422
CONTENT_TYPE_MISMATCH`; after a 422 the client may upload again. A new
intent with a different checksum for a completed asset is
`409 ASSET_ALREADY_COMPLETE`. Download of another workspace's asset is
`404 NOT_FOUND`; a rejected asset stays `409 ASSET_NOT_AVAILABLE`.

**CSV imports (IMP 01-03).** `POST /v1/imports/preview` `{"fileName",
"contentBase64", "mapping", "outflowCategoryId", "inflowCategoryId"}`
parses with the shared `csv.parse` mapping (which names `accountId` and
`encoding`), keeps raw rows and their hashes, and returns the batch:
`{"batchId", "status": "previewed | committing | committed | rolled_back",
"rowCount", "errorCount", "newCount", "duplicateCount", "totals",
"dateGap", "rows": [{"rowNumber", "date", "description", "amountMinor",
"status", "errorCode", "fingerprint", "journalId", "matches"}]}`. Rows are
keyed by the shared `csv.fingerprint`; a fingerprint already committed in
the workspace is `duplicate` (an overlapping statement), while identical
same-day rows keep distinct occurrence numbers (A11). Possible transfers
and existing entries are listed as `matches` for review, never applied.
The same file with the same settings for the same account is the same
batch. `POST /v1/imports/{batchId}/commit` `{"decisions"?: {"<row>":
"import | skip"}}` posts each new row as a `journal.post` through the
command path (`expense` to the outflow category, `income` to the inflow
category, `posted`), with journal and command ids derived from the batch
and row, so committing again creates nothing new (A12); large batches
answer `202` with a `jobId`. `POST /v1/imports/{batchId}/rollback` voids
the batch's untouched journals with `journal.correct` and lists edited
ones for review. `GET /v1/imports/{batchId}?offset&limit` pages the rows.

**Jobs, exports and deletion.** `GET /v1/jobs/{id}` returns `{"id", "type",
"status": "queued | running | succeeded | failed", "attempts", "result",
"error"}`. `POST /v1/exports` returns `202 {"exportId", "jobId"}`; the job
writes a ZIP with `entities/<entityType>.json`, original receipt documents
under `receipts/<receiptId>/<assetId>` and `manifest.json` (schema version,
workspace currency and timezone, effective date semantics,
`acceptedSequence`, counts, relationships, and the path, size and SHA-256
of every file); `GET /v1/exports/{id}/download` returns `{"downloadUrl",
"expiresAt"}` or `409 EXPORT_NOT_READY`. `DELETE /v1/workspaces/{id}`
(owner) revokes every device at once and returns `202` with a deletion
whose progress `GET /v1/workspaces/{id}/deletion` reports to the requester.

**Errors.** Non-2xx responses are `{"error", "message", "correlationId"}`;
every response carries `X-Correlation-Id`.

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
