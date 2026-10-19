# Finance sync service

The optional cloud synchronisation service: a Java 25 / Spring Boot modular
monolith (`server/app`) with the shared finance rules in `server/finance-core`.
The client contract is `spec/sync/protocol.md`.

| Task | Command |
| --- | --- |
| Build and test (Testcontainers through the Podman socket) | `gradle25w build` |
| One test class | `gradle25w :server:app:test --tests '*SyncCommands*'` |
| Run locally (PostgreSQL, MinIO and an OIDC issuer on localhost) | `SPRING_PROFILES_ACTIVE=local gradle25w :server:app:bootRun` |

The same image runs two workloads: the API (`FINANCE_WORKER_ENABLED=false`)
and the background worker (`FINANCE_WORKER_ENABLED=true`), which runs jobs,
scheduled maintenance and the start-up tasks below.

## Operations

### Object storage lifecycle

At start-up the worker puts lifecycle rules on the bucket (SEC 06). The API
workload never changes bucket configuration, so only the worker's identity
needs `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration`.

| Rule | Applies to | Action |
| --- | --- | --- |
| `finance-abort-incomplete-uploads` | the whole bucket | abort multipart uploads 1 day after they start |
| `finance-expire-staging-uploads` | `workspaces/` objects tagged `finance-retention=staging` | expire 1 day after upload |
| `finance-expire-exports` | `workspaces/` objects tagged `finance-retention=export` | expire after `finance.storage.export-retention` |

Lifecycle filters match key prefixes, not wildcards, so the staging uploads
under `workspaces/{workspaceId}/uploads/` and the archives under
`workspaces/{workspaceId}/exports/` are recognised by an object tag: the
presigned upload signs `x-amz-tagging: finance-retention=staging` (clients
send every header of the upload intent) and the export job tags each archive
`finance-retention=export`. Verified receipt documents are copied to their
permanent key without a tag and never expire.

Applying the rules replaces only rules whose identifier starts with
`finance-` and keeps every other rule on the bucket, so restarting the worker
is harmless and operators can add their own rules. MinIO has no
`AbortIncompleteMultipartUpload` action and rejects a configuration that
contains one; the worker then logs a warning and applies the two expiry
rules alone, and MinIO removes stale multipart uploads itself (after 24 hours
by default). Any other rejection stops the worker from starting.

| Setting | Environment variable | Default |
| --- | --- | --- |
| `finance.storage.export-retention` | `FINANCE_EXPORT_RETENTION` | `7d`, rounded up to whole days |
| `finance.storage.manage-lifecycle` | `FINANCE_S3_MANAGE_LIFECYCLE` | `true`; set `false` when infrastructure code owns the bucket's lifecycle |

An export older than the retention answers `410 EXPORT_EXPIRED` on download;
the user starts a new one.
