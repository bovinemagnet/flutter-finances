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

### Metrics

Every instance exposes Prometheus metrics at `/actuator/prometheus` without
a token, so block that path at the public ingress. Besides the
sync, ledger, receipt, import, job and deletion metrics, two groups serve
operations directly:

| Metric (Prometheus name) | Type | Meaning |
| --- | --- | --- |
| `finance_extraction_latency_seconds{job, outcome}` | timer with histogram buckets | duration of each server-side extraction job; today `job="receipts.scan"` with `outcome` `available`, `rejected` or `error` |
| `finance_backup_last_success_seconds{kind}` | gauge | epoch seconds when the latest successful run of `kind` finished; `0` when none was ever reported |
| `finance_backup_recovery_point_seconds{kind}` | gauge | epoch seconds of the latest point a successful `database` or `objects` backup restores to |
| `finance_backup_failures_total{kind}` | counter | failed runs reported to this instance |

The backup gauges are read from the database, so every instance reports the
same values; aggregate them with `max`. Failures are counted per instance;
aggregate them with `sum`.

### Backup reporting

The backup and restore tooling reports every run to the service (NFR 08:
recovery point at most 15 minutes, a restore drill proving database and
object consistency). The endpoint accepts only access tokens carrying the
`finance.ops` scope (authority `SCOPE_finance.ops`), for example a
client-credentials client of the OIDC provider used only by that tooling;
user tokens get `403 FORBIDDEN`.

```
POST /v1/ops/backups
Authorization: Bearer <token with scope finance.ops>
Content-Type: application/json

{"kind": "database", "outcome": "success",
 "completedAt": "2026-10-20T01:00:00Z", "recoveryPointAt": "2026-10-20T00:59:30Z"}
```

| Field | Values |
| --- | --- |
| `kind` | `database` (PostgreSQL backup or WAL archive), `objects` (object storage replication or backup), `restore-drill` |
| `outcome` | `success` or `failure` |
| `completedAt` | when the run finished (ISO 8601 UTC, at most 5 minutes ahead of the server clock) |
| `recoveryPointAt` | optional; for a successful `database` or `objects` run, the latest point it restores to (for continuous WAL archiving, the last archived transaction). Defaults to `completedAt`; never after it |

The answer is `200 {"kind", "lastSuccessAt", "recoveryPointAt",
"lastFailureAt"}`, the stored status of that kind. A report of an older run
never moves the last success or recovery point back, so retries and late
reports are harmless. An invalid report is `400 INVALID_REQUEST`.

### Alert rules

An example Prometheus rule file for the NFR 08 targets. Report the database
recovery point at least every few minutes (for example after each WAL
segment is archived) so that the 15 minute alert means a real gap, not a
quiet reporter.

```yaml
groups:
  - name: finance-backups
    rules:
      - alert: FinanceRecoveryPointTooOld
        # Recovery point objective: at most 15 minutes of data at risk.
        expr: time() - max by (kind) (finance_backup_recovery_point_seconds{kind=~"database|objects"}) > 15 * 60
        for: 5m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.kind }} recovery point is {{ $value | humanizeDuration }} old (target 15 minutes)"
      - alert: FinanceRestoreDrillOverdue
        # A restore drill must have succeeded within the last 90 days.
        expr: time() - max(finance_backup_last_success_seconds{kind="restore-drill"}) > 90 * 24 * 60 * 60
        labels:
          severity: ticket
        annotations:
          summary: "The last successful restore drill was {{ $value | humanizeDuration }} ago (target 90 days)"
      - alert: FinanceBackupFailed
        expr: sum by (kind) (increase(finance_backup_failures_total[1h])) > 0
        labels:
          severity: ticket
        annotations:
          summary: "A {{ $labels.kind }} backup run failed in the last hour"
      - alert: FinanceBackupMetricsMissing
        expr: absent(finance_backup_last_success_seconds{kind="database"})
        for: 15m
        labels:
          severity: page
        annotations:
          summary: "No sync service instance exposes backup metrics"
  - name: finance-extraction
    rules:
      - alert: FinanceExtractionSlow
        expr: histogram_quantile(0.95, sum by (le, job) (rate(finance_extraction_latency_seconds_bucket[15m]))) > 30
        for: 15m
        labels:
          severity: ticket
        annotations:
          summary: "95th percentile {{ $labels.job }} latency is {{ $value | humanizeDuration }}"
```

Because a kind that was never reported has a last success of `0`, the
restore drill alert fires until the first drill is reported, and the
recovery point alert fires until the first backup is.
