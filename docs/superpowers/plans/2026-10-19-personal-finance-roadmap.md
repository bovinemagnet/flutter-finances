# Personal Finance Application Implementation Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the P0 scope of the personal finance PRD as a local-first Flutter client with an optional Spring Boot sync service.

**Architecture:** A pure Dart domain package (`finance_core`) holds all financial rules. An encrypted SQLite package (`finance_store`) persists them and records an outbox command in the same transaction as each user action. A Flutter app (`finance_app`) provides adaptive UI and platform adapters. A Java modular monolith (`server`) validates commands, stores canonical journals in PostgreSQL, serves a cursor-based change feed and brokers receipt uploads to S3-compatible storage. Dart and Java share versioned JSON golden fixtures in `spec/fixtures`, not source code.

**Tech Stack:** Dart 3.13 / Flutter 3.47 (pub workspace), `sqlite3` with SQLite3MultipleCiphers, Java 25, Spring Boot 4.1, PostgreSQL, Liquibase, Testcontainers (Podman socket), AWS SDK v2 S3, Antora docs via `gradle25w antora`.

**Spec:** `docs/prd/initial.md`

## Global Constraints

- Money is never binary floating point. Signed 64-bit minor units, explicit currency exponent, magnitude at most `999_999_999_999_999` minor units.
- One currency per workspace (AUD default, exponent 2). Multi-currency journals are rejected.
- Every posted journal balances to zero. Debit is positive: assets and expenses increase with positive amounts; liabilities, income and equity increase with negative amounts.
- Journals in status `posted` or `reversed` form the posted ledger; `pending` only affects the pending view; `draft` affects nothing. A correction is a reversal journal plus a replacement journal linked to the original; the original's status becomes `reversed`.
- Financial effective dates are local dates (`YYYY-MM-DD`) with an explicit workspace timezone; technical events are UTC instants.
- No automatic financial action: extraction, matching, rules and insights only propose; confirmation creates commands.
- IDs are UUIDv7 strings generated offline.
- British spelling in identifiers' prose, comments, UI text and docs. Author Paul Snow, version 0.0.0.
- Use `gradle25w` instead of `./gradlew`. Final documentation lives in `src/docs` (Antora). Mermaid diagrams are external files under the Antora `examples` directory.

## Repository layout

```
pubspec.yaml                      Dart pub workspace root (sqlite3mc hook user-define)
spec/fixtures/*.json              Shared golden fixtures (schemaVersion 1)
packages/finance_core/            Pure Dart domain, no Flutter, no IO
packages/finance_store/           Encrypted SQLite persistence, outbox, file vault, sync client
apps/finance_app/                 Flutter client (Linux, Windows, macOS, iOS, Android)
server/                           Spring Boot modular monolith (Gradle subproject)
  finance-core/                   Java parity of shared financial rules (runs spec fixtures)
  app/                            API + worker (modules: workspace, sync, ledger, receipts, imports, exports, jobs)
settings.gradle.kts, build.gradle.kts   Root Gradle build (server + Antora task)
src/docs/                         Antora component
```

## Shared fixture contract

Each `spec/fixtures/<area>.json` file:

```json
{ "schemaVersion": 1, "area": "money", "cases": [ { "id": "A03-split", "op": "split.validate", "input": {}, "expect": {} } ] }
```

Operations implemented by both Dart and Java test runners:

| op | input | expect |
| --- | --- | --- |
| `money.parse` | `{text, exponent}` | `{minor}` or `{error}` |
| `money.allocate` | `{total, weights[]}` | `{parts[]}` (largest remainder, ties to lower index) |
| `journal.validate` | `{postings:[{account, minor, currency}]}` | `{errors:[codes]}` |
| `ledger.scenario` | `{accounts[], categories[], entries[]}` | `{balances{}, expenses, income, netWorth, journalCount}` |
| `periods.generate` | `{cycle, anchor, count, lengthDays?, endOfMonth?: clamp\|lastDay}` | `{periods:[{start,end}]}` |
| `schedule.occurrences` | `{frequency, interval, start, until, count}` | `{dates[]}` |
| `budget.remaining` | `{planned, rollover, adjustments, postedNet, pending}` | `{remaining, remainingAfterPending}` |
| `rollover.next` | `{policy, remaining}` | `{opening}` |
| `discretionary.estimate` | BUD 07 inputs | `{budgetLimit, cashLimit, estimate, shortfall}` |
| `csv.parse` | `{text, mapping}` | `{rows[], errors[]}` |

## Sync contract (SYNC 01–06)

Command envelope: `{commandId, workspaceId, deviceId, entityType, entityId, baseRevision, schemaVersion, type, payload, groupId?}`.
Command types: `journal.post`, `journal.correct` (atomic reversal + replacement), `entity.upsert` (metadata entity with changed field names), `entity.delete` (tombstone).
Result status: `applied | previously_applied | conflict | validation_failed | permission_denied`, with `revision`, `cursor`, and on conflict the server state.
Endpoints: `POST /v1/sync/commands`, `GET /v1/sync/changes?cursor=`, `GET /v1/sync/snapshot`, `POST /v1/receipts/upload-intents`, `POST /v1/receipts/{id}/complete`, `GET /v1/receipts/{id}/download`, `POST /v1/imports/preview`, `POST /v1/imports/{id}/commit`, `POST /v1/exports`, `GET /v1/jobs/{id}`, `POST /v1/devices`, `DELETE /v1/devices/{id}`.

## Sub-plans and tasks

### Plan 1 — Foundation (`finance_core` money and ledger)
- [x] 1.1 Workspace scaffolding, `.gitignore`, analysis options
- [x] 1.2 `Currency`, `Money`, parsing, range checks, exact allocation (fixtures: money)
- [x] 1.3 `LocalDate`, UUIDv7 ids
- [x] 1.4 Ledger model, journal validation (fixture: journal.validate, A03)
- [x] 1.5 Transaction drafts → journals: expense, income, transfer, card repayment, refund, opening balance, adjustment, reimbursement, splits (A01–A04, A07)
- [x] 1.6 Ledger projection: balances, pending view, net worth with inclusion flags, corrections, reconciliation (FIN 07, FIN 08)

### Plan 2 — Planning domain (`finance_core`)
- [x] 2.1 Budget periods (monthly EOM rule, weekly, fortnightly anchor, custom) (BUD 02, A14)
- [x] 2.2 Budget model, 50/30/20 template, versions, remaining arithmetic, rollover (BUD 01, 03)
- [x] 2.3 Goals, reservations, sinking funds, debt presentation (BUD 04–06)
- [x] 2.4 Recurrence, occurrence edits, bill matching (PLAN 01–02, A13)
- [x] 2.5 90-day forecast with scenarios (PLAN 03) and discretionary estimate (BUD 07)
- [x] 2.6 Reports, financial years, insights (REP 01–04)

### Plan 3 — Documents and imports domain (`finance_core`)
- [x] 3.1 Receipt model and state machines (REC 04), content validation rules (REC 05)
- [x] 3.2 Receipt text parser with provenance and uncertainty (OCR 01, 03, 04, A06)
- [x] 3.3 Matching and deduplication (MATCH 01–03, A08, A11)
- [x] 3.4 CSV import: mapping, parse, preview, fingerprints, idempotent batches, transfer detection, rollback (IMP 01–03, A12)
- [x] 3.5 Categorisation rules with preview and undo (AUTO 01)
- [x] 3.6 Exports: CSV with formula sanitisation, JSON archive manifest with hashes (EXP 01, DATA 01, DATA 03)

### Plan 4 — Local store (`finance_store`)
- [x] 4.1 Encrypted database open, key wrapping (platform key store or password fallback), migrations (SEC 02, NFR 11)
- [x] 4.2 Repositories and command handlers writing state + outbox atomically (SYNC 01)
- [x] 4.3 Encrypted receipt vault with durable save before success (REC 03, REC 08, NFR 10)
- [x] 4.4 Sync client: push outbox, pull changes, conflicts, cursor expiry rebuild, document uploads (SYNC 02–06)
- [x] 4.5 Backup/export/restore into isolated workspace (DATA 01–03, A16)

### Plan 5 — Server (`server/`)
- [x] 5.1 Gradle build, Java finance-core parity running all fixtures
- [x] 5.2 Workspace, membership, devices, JWT resource server, workspace scoping (SEC 01, A17)
- [x] 5.3 Sync commands with idempotency, revisions, conflicts, change feed, tombstones, snapshot (A09, A10, A15)
- [x] 5.4 Receipt upload intents, completion checks, quarantine, scoped download (SYNC 05, SEC 04)
- [x] 5.5 Job table worker, imports preview/commit, exports, deletion jobs (IMP, EXP, SEC 05–06)

### Plan 6 — Flutter client (`apps/finance_app`)
- [x] 6.1 App shell: width breakpoints, navigation, theming, accessibility, settings and onboarding (Journey A)
- [x] 6.2 Transactions: list, entry form with calculator, splits, transfers, refunds, review queue with undo (Journey C)
- [x] 6.3 Budget, goals, plan (bills, calendar, forecast), reports with tables beside charts
- [x] 6.4 Receipts: capture adapters with fallback, inbox, review, matching, search (Journey B)
- [x] 6.5 Imports UI, reconciliation, rules, insights, sync and backup settings (Journeys D, E)

### Plan 7 — Documentation
- [x] 7.1 Antora component in `src/docs`, Gradle `antora` task, architecture, domain rules, sync protocol, platform capability matrix, operations

Each sub-plan is executed TDD: failing test, minimal implementation, passing test, commit.
