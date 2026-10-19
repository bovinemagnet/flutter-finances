# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout and commands

Requirements are in `docs/prd/initial.md`; requirement IDs (`FIN 03`, `REC 04`, `SYNC 02`, acceptance tests `A01`–`A18`) are the shared vocabulary for scope and tests. The implementation roadmap is `docs/superpowers/plans/2026-10-19-personal-finance-roadmap.md`.

| Path | What it is | Commands |
| --- | --- | --- |
| `pubspec.yaml` | Dart pub workspace root (also sets the `sqlite3mc` hook so SQLite is encrypted) | `dart pub get` (run once at the root) |
| `packages/finance_core` | Pure Dart domain: money, ledger, planning, documents/imports | `dart test`, `dart test test/ledger_test.dart -N "A01"`, `dart analyze` |
| `packages/finance_store` | Encrypted SQLite store, outbox, receipt vault, sync client, backup | `dart test`, `dart analyze` |
| `apps/finance_app` | Flutter client (iOS, Android, Windows, macOS, Linux) | `flutter test`, `flutter test test/unit/app_state_test.dart`, `flutter analyze`, `flutter run -d linux` |
| `server/finance-core`, `server/app` | Java 25 / Spring Boot 4.1 sync service (Gradle subprojects) | `gradle25w build`, `gradle25w :server:app:test --tests '*SyncCommands*'`, `SPRING_PROFILES_ACTIVE=local gradle25w :server:app:bootRun` |
| `spec/fixtures/*.json` | Golden fixtures run by both the Dart and Java test suites | change a rule here first |
| `spec/sync/protocol.md` | Client/server sync contract | |
| `src/docs` | Antora documentation | `gradle25w antora` |

Always use `gradle25w`, never `./gradlew`. Server integration tests use Testcontainers through the Podman socket (configured in the Gradle `test` task). Run every package's tests after merging changes from another package: a new export in `finance_core` can clash with names in `finance_store` or Flutter (for example `Split` clashes with Flutter's animation `Split`; hide one).

## Architecture

- **Clients:** Flutter for iOS, Android, Windows, macOS and Linux. Dart packages organised by domain (accounts/ledger, budgeting, planning, receipts, imports, sync, reporting), with UI, business rules, persistence and platform services kept separate. State lives in an `AppState` `ChangeNotifier` exposed through `AppScope` (an `InheritedNotifier`); Riverpod and Drift were proposed in the PRD but not adopted.
- **Local storage:** `finance_store` — SQLite3MultipleCiphers database plus an AES-GCM receipt vault; the data key is held in the platform key store or wrapped with an Argon2id password. Every user action and its outbox command are saved in one transaction (`SYNC 01`). Typed tables hold accounts, categories, journals and postings; every other entity type (budget plans, schedules, receipts, rules…) is stored generically as JSON via `upsertEntity` and synced as `entity.upsert` with field-level revisions. The app's entity type names are in `apps/finance_app/lib/data/entity_types.dart` and `receipt_service.dart`/`import_service.dart`.
- **Backend (optional sync):** Java/Spring Boot modular monolith (Quarkus is an allowed substitute, but never both), PostgreSQL with Liquibase, S3-compatible private object storage, and a background worker deployed from the same codebase. REST + OpenAPI with versioned command envelopes; no GraphQL mutations.
- **Platform services** sit behind interfaces (`ReceiptScanner`, `TextRecognizer`, `SecureKeyStore`, `FileImporter`, `ShareInbox`, `Notifications`, `BackgroundScheduler`). Do not scatter platform conditionals through finance code. Layouts are driven by width breakpoints (compact < 600, medium 600–1023, expanded ≥ 1024), not by OS checks.
- Only the Linux desktop build can be produced and run on this development machine; Android, iOS, macOS and Windows builds must be made on their own operating systems (the iOS share extension target has not been added yet).

## Financial invariants that must not be broken

These rules cut across several PRD sections and are the easiest to get wrong:

- **Money:** never binary floating point. Signed 64-bit minor units with an explicit currency exponent; percentage allocation uses exact arithmetic with a deterministic remainder. One currency per workspace in P0.
- **Double-entry ledger internally:** every journal balances to zero. User accounts map to asset/liability accounts, categories to income/expense accounts; opening equity, transfer clearing and reimbursement receivables are system accounts. The UI never exposes accounting terminology.
- **No double counting:** transfers are not income/expense; card repayments do not re-count the purchase; attaching a receipt never creates a second expense; a posted bill or pending item replaces its forecast item; a bank import matching a receipt-created entry enriches provenance rather than adding a purchase.
- **Immutable financial history:** financial corrections are a reversal plus replacement linked to the original; refunds do not rewrite earlier periods; historical budget versions are retained. Balances are projections derived from journals, never an independently editable cached value.
- **Status separation:** draft, pending, posted and reversed are distinct; drafts do not affect balances and pending does not touch the posted ledger.
- **Dates:** UTC instants for technical events; local date plus explicit workspace timezone for financial effective dates. Never approximate a month as four weeks; monthly schedules need an explicit end-of-month rule.
- **No automatic financial actions:** extracted receipt data, matches, rules and insights always require user confirmation before posting or moving money. Any future LLM/cloud extraction is an isolated, consented adapter that cannot invoke commands or approve matches.

## Sync and receipts

- Commands carry `commandId`, `workspaceId`, `deviceId`, `entityId`, `baseRevision`, `schemaVersion`, `payload`; the server applies them idempotently and appends a change record in the same transaction. Concurrent edits to amounts, splits, reconciliations or deletions produce a reviewable conflict, never last-write-wins.
- Receipt bytes go directly to object storage via short-lived upload intents, separate from financial command payloads. A receipt must be durably saved locally before reporting "Saved"; OCR failure never destroys it, and unsynced originals are never evicted.

## Testing approach

Dart and Java implementations share versioned golden fixtures (money arithmetic, transfers, refunds, reconciliation, budget periods, forecasts), not source code; both must pass identical examples. Add property-based checks for balanced journals and repeated command delivery. The acceptance scenarios in PRD §16 are release criteria and good seeds for tests.

## Conventions

- Australian defaults: AUD, Australian date formats, fortnightly pay cycles, July–June financial year. Use British spelling in code comments, UI text and documentation.
