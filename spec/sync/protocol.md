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
  applied; otherwise fields merge (SYNC 03). A field the server never had
  has not changed, so adding it merges even when `baseRevision` is behind
  (or 0 for two devices creating the same derived entity). Never last
  write wins.
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
2. The client PUTs the bytes with every header in `headers` (they are
   signed; they include `x-amz-tagging: finance-retention=staging`, which
   lets the bucket lifecycle expire an upload that is never completed
   after one day), then `POST /v1/receipts/{receiptId}/complete`
   with `{"assetId"}`. The server verifies ownership, size, checksum and
   content type by magic bytes, then marks the asset `quarantined` until the
   scan job marks it `available` or `rejected`. Completing twice is a no-op;
   it never creates a second receipt.
3. `GET /v1/receipts/{receiptId}/assets/{assetId}/download` returns
   `{"downloadUrl", "expiresAt"}`, a short-lived presigned GET, only for
   members of the owning workspace (A17). While the asset is still uploading
   or quarantined it returns HTTP 409 `{"error": "ASSET_NOT_AVAILABLE"}`.

## Households

A workspace can be shared by several signed-in users (P1, SEC 05). Every
membership has one role; every account is private to the user who created
it until that user shares it. Endpoints take the workspace from the path and
authenticate as described under "Server behaviour"; a caller who is not a
member gets `404 WORKSPACE_NOT_FOUND`.

**Roles.**

| Action | owner | member | viewer |
| --- | --- | --- | --- |
| Pull the change feed and snapshot, read reports, start and download exports | yes | yes | yes |
| Register devices, list and revoke their own devices | yes | yes | yes |
| Submit sync commands, preview, commit and roll back imports, upload receipt documents | yes | yes | no |
| Invite, list and revoke invitations, change roles, remove other members | yes | no | no |
| List every member's devices and revoke any of them | yes | no | no |
| Read audit events, delete the workspace | yes | no | no |
| List members, leave the workspace | yes | yes | yes |

A viewer's command is `permission_denied` with `errors: ["NOT_PERMITTED"]`;
a viewer's import or receipt upload call is `403 READ_ONLY`; an owner-only
call by anyone else is `403 OWNER_REQUIRED`. Roles never widen what a user
can see: an owner does not see another member's private accounts either.

**Invitations.** An owner creates one with
`POST /v1/workspaces/{workspaceId}/invitations` `{"role": "member" |
"viewer", "expiresInHours"?}` (default 72 hours, at most 30 days; `400
INVALID_ROLE`, `400 INVALID_EXPIRY`) and receives `201 {"id",
"workspaceId", "role", "status": "pending", "createdAt", "expiresAt",
"acceptedAt": null, "token"}`. The token is 256 random bits, returned only in
this response (the server keeps its SHA-256) and handed to the invitee out of
band together with the workspace and invitation ids. `GET
/v1/workspaces/{workspaceId}/invitations` lists invitations newest first with
`status` `pending`, `expired`, `accepted` or `revoked` and `token: null`.
`DELETE /v1/workspaces/{workspaceId}/invitations/{invitationId}` revokes a
pending or expired invitation (`204`; otherwise `409
INVITATION_NOT_PENDING`). Owners are made by changing a role, never by
invitation.

**Acceptance.** The invitee, signed in as any user,
calls `POST /v1/workspaces/{workspaceId}/invitations/{invitationId}/accept`
`{"token"}` and receives `200 {"workspaceId", "role"}`, then registers a
device with `POST /v1/devices` and bootstraps from the change feed. An
invitation is single use: an unknown invitation, a wrong token or an
inactive workspace is `404 INVITATION_NOT_FOUND` (nothing is revealed before
the token is proven); afterwards a used invitation is `409 INVITATION_USED`
(the same user accepting again gets `200` with the same answer), a revoked
one `410 INVITATION_REVOKED`, an expired one `410 INVITATION_EXPIRED`, and a
user who is already a member `409 ALREADY_MEMBER`.

**Members and removal.** `GET /v1/workspaces/{workspaceId}/members` returns
`[{"userId", "role", "joinedAt", "you"}]`, owners first. An owner changes a
role with `PATCH /v1/workspaces/{workspaceId}/members/{userId}` `{"role":
"owner" | "member" | "viewer"}` (`204`; `400 INVALID_ROLE`, `404
MEMBER_NOT_FOUND`). `DELETE /v1/workspaces/{workspaceId}/members/{userId}`
removes a member (owners) or leaves (a member's own `userId`) and, in the
same transaction, revokes every device that user registered in the
workspace: their next sync call is `403 DEVICE_REVOKED` and every
workspace call `404 WORKSPACE_NOT_FOUND`. The last owner can be neither
demoted nor removed (`409 LAST_OWNER`). Invitations, acceptance, role
changes, removals and device registrations are audit events
(`GET /v1/workspaces/{workspaceId}/audit-events?limit&before`, owners).

**Account sharing.** An account's `sharing` field is `"private"` (the
default when absent) or `"shared"` (`INVALID_FIELD` otherwise). Only the
user who created the account may change it; anyone else's command is
`permission_denied` (`NOT_PERMITTED`). Accounts created by server work
without a calling user, or before the server recorded creators, are visible
to everyone.

**What each member sees.** For a user, an account is *hidden* when it is
private and another user created it. Then:

- an account is visible unless hidden;
- every category is visible;
- a journal is hidden when any of its postings names a hidden account (a
  transfer between a shared and a private account is hidden as a whole);
- any other entity is hidden when one of `accountId`, `counterAccountId`,
  `toAccountId`, `fromAccountId` or `accountIds` names a hidden account, or
  one of `journalId` or `journalIds` names a hidden journal; all other
  metadata (budget plans, rules, schedules without such references, and so
  on) is visible;
- a tombstone is never hidden: delete changes carry only `{"id"}`.

The change feed applies these rules to each change, judging the entity
data in that change against the accounts hidden at the time of the pull:
hidden changes are skipped, so a page may hold fewer than `limit` changes
(or none) while `hasMore` is true. When an entity leaves a member's view (the
account becomes private, or a journal or reference is edited to point at a
hidden account) the member receives a `delete` change for it; when it
enters their view they receive an `upsert` with the full entity. Sharing or
unsharing an account re-announces, in the same transaction, every journal
posting to it and every entity referring to it or to those journals, so
each member gains or drops them together. Clients ignore a `delete` for an
entity they never had. The snapshot returns only visible live entities (a
page may again be shorter than `limit`). Reports and exports are computed
from visible entities only; a report's `complete` is `false` when some
account was hidden. For commands, a hidden entity is `permission_denied`
(`NOT_PERMITTED`) for upsert, delete, `journal.post` replacement and
`journal.correct`, and a posting to a hidden account is
`validation_failed` with `UNKNOWN_LEDGER_ACCOUNT`, exactly as for an account
that does not exist. An import whose account is hidden is `404
IMPORT_NOT_FOUND` (`400 UNKNOWN_ACCOUNT` on preview), and downloading an
asset of a hidden receipt is `404 NOT_FOUND`.

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
`deviceId` differs from the calling device's is `permission_denied` with
`errors: ["NOT_PERMITTED"]`. Every result carries `errors`, empty when
there are none. Clients send `X-Device-Id` (their own device id) on every
API call and `X-Workspace-Id` once synced and with a bootstrap preview;
presigned object storage URLs never receive these headers or the token.

**Identifiers.** `commandId`, `workspaceId`, `deviceId`, `entityId`,
`receiptId` and `assetId` are UUIDs (a malformed command is
`INVALID_COMMAND`). An entity id is unique across entity types within a
workspace: reusing another type's id is `ENTITY_TYPE_MISMATCH`. An entity
that belongs to another one, such as a journal's `journalAnnotation` or an
entry's review state, therefore never reuses its owner's id; clients
derive a name-based UUID from the owner's id (the same on every device, so
concurrent edits still merge) and name the owner in a field such as
`journalId`.

**Setup.** `POST /v1/workspaces` `{"id"?, "name", "currency", "timezone"}`
creates a workspace owned by the caller (`id` may be generated offline; a
deleted workspace's id is refused with `409 WORKSPACE_DELETED`, so a restore
always creates a new workspace, DATA 03) and answers `201` with the
workspace; an id that already exists is `409 WORKSPACE_EXISTS`, so a client
retrying after a lost answer reads `GET /v1/workspaces/{id}` instead.
`GET /v1/workspaces` lists the caller's workspaces as `[{"id", "name",
"currency", "currencyExponent", "timezone", "role"}]` and
`GET /v1/workspaces/{id}` returns the bootstrap
settings (currency and exponent, timezone, `schemaVersion`,
`tombstoneHorizonDays`, `maxCommandsPerBatch`, `serverTime`).
`POST /v1/devices` `{"deviceId", "workspaceId", "name", "platform"}`
registers a device (repeating it is harmless); `DELETE /v1/devices/{id}`
revokes it for good (its owner or a workspace owner). A device must be
registered before it previews a bootstrap, which reads `/v1/sync/changes`.

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
HEIC, HEIF, PDF; `400 UNSUPPORTED_CONTENT_TYPE`), up to 20 MiB
(`400 TOO_LARGE`), with a lower-case hex `sha256` (`400 INVALID_CHECKSUM`).
These limits match the client's `ContentLimits` (REC 05): a receipt's
source documents hold at most 10 pages together, counted at completion
(a PDF as the shared `pdf.inspect` fixture counts, at least one; an image
is one page; derivatives are renderings and do not count), and the scan
rejects images wider or taller than 16,384 pixels or larger than 50
megapixels (`IMAGE_TOO_LARGE`).
Uploads go to a staging key; completion copies verified bytes to the
asset's permanent key, so a late or repeated upload cannot replace them.
Completion answers `200 {"status": "quarantined" | "available" |
"rejected"}`, `404 UNKNOWN_ASSET`, `409 OBJECT_MISSING` (nothing uploaded),
or `422 CHECKSUM_MISMATCH` (size or checksum), `422
CONTENT_TYPE_MISMATCH` and `422 TOO_MANY_PAGES`; after a 422 the client may
upload again. A new
intent with a different checksum for a completed asset is
`409 ASSET_ALREADY_COMPLETE`. Download of another workspace's asset, or
of one with no upload intent yet, is `404 NOT_FOUND`; a rejected asset
stays `409 ASSET_NOT_AVAILABLE`. Clients treat both as "Image pending".

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

**Reports (REP 01, REP 04).** `GET /v1/reports/{kind}` computes one of the
shared `report.compute` definitions (`spec/fixtures/reports.json`) over the
workspace's canonical accounts, categories and journals: `income-vs-expenses`,
`spending-by-category`, `spending-by-payee`, `net-worth-history` and
`cash-flow` take exactly one period, `from` and `to` (inclusive
`YYYY-MM-DD`), `financialYear=2026` (1 July 2026 to 30 June 2027, labelled
`FY2026-27`) or `calendarYear=2026`, covering at most 100 years;
`account-balances` takes an optional `asOf` date (all time when absent) and
no period; `cash-flow` also needs `accountIds` (repeated or
comma-separated). Any member, viewers included, may read reports. The
answer is `{"kind", "title", "keyLabel", "currency", "currencyExponent",
"range": {"start", "end", "label"} | null, "asOf", "complete", "columns":
[{"key", "label", "kind": "money | count"}], "rows": [{"key", "label",
"amounts": {"<column>": minor units}, "counts": {}, "journalIds": [...]}]}`,
where `journalIds` lists the journals behind each row for drill-through.
Only the posted ledger counts (posted and reversed journals; drafts and
pending entries are ignored). Accounts the member may not see, and every
journal posting to one, are removed before the report is computed (see
"Households"), and `complete` is then `false`; it is `true` when the member
sees every account. A server report covers only accepted commands, so it
never includes a device's unsynchronised changes. Errors: `404
UNKNOWN_REPORT`, `400 INVALID_PERIOD` (missing, mixed or malformed period,
`to` before `from`, or a period for `account-balances`), `400
INVALID_REQUEST` (`cash-flow` without `accountIds`) and `400 UNKNOWN_ACCOUNT`
(an `accountIds` entry that does not exist or that the member may not see;
the two are indistinguishable).

**Jobs, exports and deletion.** `GET /v1/jobs/{id}` returns `{"id", "type",
"status": "queued | running | succeeded | failed", "attempts", "result",
"error"}`. `POST /v1/exports` returns `202 {"exportId", "jobId"}`; the job
writes a ZIP with `entities/<entityType>.json`, original receipt documents
under `receipts/<receiptId>/<assetId>` and `manifest.json` (schema version,
workspace currency and timezone, effective date semantics,
`acceptedSequence`, counts, relationships, and the path, size and SHA-256
of every file); `GET /v1/exports/{id}/download` returns `{"downloadUrl",
"expiresAt"}`, `409 EXPORT_NOT_READY`, or `410 EXPORT_EXPIRED` once the
archive is older than the export retention (7 days by default; the bucket
lifecycle then deletes it). `DELETE /v1/workspaces/{id}`
(owner) revokes every device at once and returns `202` with a deletion
whose progress `GET /v1/workspaces/{id}/deletion` reports to the requester.
The deletion's suppression record outlives the workspace (SEC 06): if a
restored database backup brings a deleted workspace back, the server
treats it as gone at once (`404 WORKSPACE_NOT_FOUND` for workspace and
receipt calls and device registration, `403 DEVICE_REVOKED` on
`/v1/sync/*`, `409 WORKSPACE_DELETED` on creation), and the worker erases
it again with every module's purger at startup and every 15 minutes.

**Errors.** Non-2xx responses are `{"error", "message", "correlationId"}`;
every response carries `X-Correlation-Id`.

## Optional cloud extraction (AUTO 02, P1)

Cloud extraction of receipt text is off unless the deployment configures a
provider and a workspace owner consents. Its consent is separate from
cloud sync consent (SEC 05). No provider is configured by default.

**Consent.** `GET /v1/workspaces/{id}/extraction-consent` (owners only;
another member is `403 OWNER_REQUIRED`, a non-member `404
WORKSPACE_NOT_FOUND`) returns `{"workspaceId", "status": "none | granted |
withdrawn", "providerName", "disclosedRetention", "grantedAt",
"withdrawnAt", "available", "offeredProvider", "offeredRetention"}`.
`available` is false when no provider is configured; the client shows
`offeredProvider` and `offeredRetention` before asking for consent.
`PUT` of the same path with `{"granted": true, "providerName",
"disclosedRetention"}` records consent; both values must repeat what was
offered (`400 PROVIDER_MISMATCH`, `400 RETENTION_MISMATCH`), so a
recorded consent always names the provider and retention the owner saw,
and with no provider it is `409 EXTRACTION_UNAVAILABLE`. `{"granted":
false}` withdraws consent and deletes every extraction result of the
workspace in the same transaction. Both answer the consent view and are
audited (`extraction.consent_granted`, `extraction.consent_withdrawn`).
Consent covers one named provider: if the deployment's provider changes,
nothing is sent until an owner consents again.

**Extraction.** When the scan releases a `source` asset while consent to
the configured provider stands, the server queues a `receipts.extract`
job. The job checks consent again, sends the document to the isolated
provider adapter and stores what it returns; storing locks the consent
record, so a result is never kept after a withdrawal. The adapter returns
recognised text and lines only. It has no access to commands, the ledger,
matching or other workspace data, and it returns no amounts, merchants,
dates or actions. Its job result holds identifiers and a status
(`extracted` or `skipped`), never text.

**Results.** `GET /v1/receipts/{receiptId}/extraction` returns
`{"receiptId", "untrusted": true, "results": [{"assetId", "provider",
"text", "lines", "extractedAt"}]}` to members who may see the receipt.
Another workspace's receipt, a hidden receipt or a deleted receipt is
`404 NOT_FOUND`, and a receipt without results is `404
EXTRACTION_NOT_FOUND`. Receipt text is untrusted data: the server removes
control characters (keeping line breaks and tabs in `text`) and bounds it
to 20,000 characters, 500 lines and 500 characters per line, but never
interprets it. Clients display it as plain text and may use it only to
pre-fill a draft the user reviews; it can never post, change an amount or
approve a match. Results are deleted when consent is withdrawn, when the
receipt entity is deleted (in the deleting command's transaction) and by
the workspace deletion job.

## Bank feeds (BANK 01-03, P1)

**Pending business decision.** No real provider is wired. Choosing an
Australian Consumer Data Right provider, and the participation model the
application operates under (for example as a CDR representative of an
accredited intermediary, or as an accredited recipient itself), is a
pending business decision (BANK 01). Until it is made, only the
deterministic `sandbox` provider exists, and only when
`finance.bank-feeds.sandbox.enabled` is true. The application never asks
for bank passwords: consent is given at the provider or data holder
through the provider's consent URL. The application stays fully useful
through manual entry and CSV import whenever a provider is unavailable.

**Adapter boundary.** Each provider is a server-side `BankFeedProvider`
adapter that lists shared accounts, fetches an account's transactions
after a cursor (with provider ids, `pending | posted` status, the pending
id a posted transaction settles, a previous id when the provider changed
it, and the transaction a reversal reverses), reports consent status and
expiry, refreshes and revokes tokens. Provider tokens never reach clients
or logs; they are stored AES-GCM encrypted (a fresh nonce each time, the
connection id as associated data) with a key from configuration
(`finance.bank-feeds.token-key`, base64; without it connecting is `409
BANK_FEEDS_UNAVAILABLE`).

**Connections.** All endpoints take `X-Workspace-Id` (or `X-Device-Id`);
another workspace's connection is `404 CONNECTION_NOT_FOUND`, and viewers
can read but not change. A connection is:

```json
{
  "id": "uuid", "provider": "sandbox",
  "institution": {"id": "sandbox-bank", "name": "Sandbox Bank"},
  "sharedAccounts": [{"id", "name", "type", "maskedNumber"}],
  "dataScope": ["bank:accounts.basic:read", "bank:transactions:read"],
  "purpose": "Suggest entries from my bank transactions",
  "consentStatus": "pending | active | expired | revoked",
  "consentExpiresAt": "instant", "lastSuccessfulRefreshAt": "instant",
  "stale": false, "error": {"code": "RATE_LIMITED", "at": "instant"},
  "nextRefreshAt": "instant", "createdAt": "instant", "revokedAt": null,
  "consentUrl": "https://... (only when the user must consent at the provider)"
}
```

Absent values are omitted. `stale` is true when an active feed has not
refreshed successfully for `finance.bank-feeds.stale-after` (36 hours);
clients show stale feeds prominently and never present a connected
account as real-time.

- `POST /v1/bank-feeds/connections` `{"provider", "institutionId"?,
  "dataScope"?, "purpose"}` answers `201` with the connection. A real
  provider returns `consentStatus: pending` and a `consentUrl`; the sandbox
  grants at once and queues the backfill. `400 UNKNOWN_PROVIDER`,
  `400 PURPOSE_REQUIRED` (blank or over 500 characters), `400
  INVALID_SCOPE` (only the two scopes above may be requested).
- `POST /v1/bank-feeds/connections/{id}/consent-callback` `{"state",
  "code"}` completes a redirect consent: `400 INVALID_CONSENT_STATE` when
  the state does not match the one in the consent URL (only its SHA-256 is
  stored), `409 CONSENT_REJECTED` when the provider refuses the code, `409
  CONSENT_NOT_PENDING` when nothing is waiting.
- `GET /v1/bank-feeds/connections` and `GET /v1/bank-feeds/connections/{id}`.
- `POST /v1/bank-feeds/connections/{id}/refresh` answers `202 {"jobId"}`;
  `409 CONSENT_EXPIRED`, `409 CONSENT_PENDING` or `409 CONNECTION_REVOKED`
  when nothing may be collected.
- `POST /v1/bank-feeds/connections/{id}/reconnect` renews consent and
  keeps the connection's records and cursors, so nothing is proposed twice;
  it may return a `consentUrl`. A revoked connection is `409
  CONNECTION_REVOKED`: connect again instead.
- `DELETE /v1/bank-feeds/connections/{id}` revokes: consent is withdrawn at
  the provider (best effort), the tokens are deleted and collection stops
  for good; a refresh already queued collects nothing. Existing provider
  records and decisions are kept until the workspace is deleted.

Creating, connecting, reconnecting and revoking are audited
(`bank_feed.*`). Workspace deletion withdraws consent at each provider
(best effort) and deletes connections, tokens, accounts and records.

**Refresh.** The `bankfeeds.refresh` job renews the access token when it
is due, confirms the consent is still active (otherwise the connection
becomes `expired` and its tokens are deleted), refreshes the shared
accounts and pages each account from its stored cursor; the first run is
the backfill. Each page and its cursor commit together, after locking the
connection, so nothing is collected once a revocation has committed. When
the provider rate-limits, the connection records `error.code
RATE_LIMITED` and `nextRefreshAt`, and the job queues its own retry after
the base delay (`refresh-base-backoff`, 1 minute) doubled for each
consecutive limit, at least the provider's requested delay and at most
`refresh-max-backoff` (6 hours); after `max-rate-limit-retries` (8) it
waits for the next manual refresh or webhook. Success clears the error
and sets `lastSuccessfulRefreshAt`.

**Webhooks.** `POST /v1/bank-feeds/webhooks/{provider}` needs no user
token. The provider signs each delivery with its configured secret
(`finance.bank-feeds.webhook-secrets.<provider>`): `X-Webhook-Id` (the
delivery id), `X-Webhook-Timestamp` (Unix seconds) and
`X-Webhook-Signature: v1=<hex HMAC-SHA256 of "<id>.<timestamp>.<raw
body>">`. A bad or missing signature is `401 INVALID_SIGNATURE`, a
timestamp more than `webhook-tolerance` (5 minutes) from the server clock
is `401 TIMESTAMP_OUT_OF_TOLERANCE`, and an unknown provider is `404`. A
delivery id already handled answers `200 {"status": "duplicate"}` and does
nothing; otherwise `202 {"status": "accepted"}`. The body `{"type",
"connectionReference"}` only triggers work: `transactions.updated` queues
a refresh, `consent.revoked` ends collection and deletes the tokens,
`consent.expired` marks the consent expired. Unknown types and unknown or
inactive connections are acknowledged and ignored, so a webhook reveals
nothing. Webhooks never carry transactions the server trusts.

**Provider records and proposals.** Provider transactions are stored as
provider records, separate from canonical journals, and are never posted
automatically. `GET /v1/bank-feeds/{connectionId}/proposals?status=open |
all | superseded | accepted | dismissed` (default `open`) returns
`{"connectionId", "proposals": [{"recordId", "accountId",
"providerTransactionId", "previousProviderTransactionIds", "status":
"pending | posted", "amountMinor", "currency", "date", "description",
"kind": "new | settles_pending | reversal", "relatedRecordId",
"settledByRecordId", "reversedByRecordId", "proposalStatus", "journalId",
"firstSeenAt"}]}`. Descriptions are untrusted provider text. The client
turns an accepted proposal into a journal through the normal command path
(posted, or pending for a pending record, which never touches the posted
ledger) and then records the decision with
`POST /v1/bank-feeds/{connectionId}/proposals/{recordId}/decision`
`{"decision": "accepted | dismissed", "journalId"?}`; the journal must be
a live journal of the workspace (`400 JOURNAL_NOT_FOUND`), and a proposal
that is no longer open is `409 PROPOSAL_DECIDED`. Reconciliation is
explicit and idempotent:

- the same provider id again updates a pending record and is otherwise
  ignored;
- a pending transaction that posts arrives as a posted record of kind
  `settles_pending`, linked both ways (`relatedRecordId`,
  `settledByRecordId`). If the pending proposal was still open it becomes
  `superseded`; if it was accepted it keeps its `journalId`, and the
  client settles that entry rather than adding a second purchase;
- a provider id change renames the existing record and lists the old id
  in `previousProviderTransactionIds`; a late delivery under the old id is
  ignored;
- a reversal is a record of kind `reversal`, linked both ways
  (`relatedRecordId`, `reversedByRecordId`); the user decides how to
  correct any journal created from the original (a reversal plus
  replacement, never an edit of posted history).

A provider that drops a pending transaction without posting it, or
changes an id without reporting the previous one, cannot be detected by
cursor-based collection; the user reviews such cases as ordinary
proposals.

**Sandbox.** The `sandbox` provider is a fake institution ("Sandbox
Bank") with two accounts and a fixed timeline measured from when the
connection was first made: day 0 has three posted transactions and one
pending purchase; day 1 posts that purchase under a new id and adds a
subscription; day 2 changes a transaction's id and reverses the
subscription. Its consent lasts 90 days and pages hold two transactions.

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
