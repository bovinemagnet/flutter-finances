# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout and commands

Requirements are in `docs/prd/initial.md`; requirement IDs (`FIN 03`, `REC 04`, `SYNC 02`, acceptance tests `A01`–`A18`) are the shared vocabulary for scope and tests. The implementation plans are `docs/superpowers/plans/2026-10-19-personal-finance-roadmap.md` (P0) and `docs/superpowers/plans/2026-10-19-p1-and-release.md` (P1 and release engineering).

| Path | What it is | Commands |
| --- | --- | --- |
| `pubspec.yaml` | Dart pub workspace root (also sets the `sqlite3mc` hook so SQLite is encrypted) | `dart pub get` (run once at the root) |
| `packages/finance_core` | Pure Dart domain: money, ledger, planning, documents/imports | `dart test`, `dart test test/ledger_test.dart -N "A01"`, `dart analyze` |
| `packages/finance_store` | Encrypted SQLite store, outbox, receipt vault, sync client, backup | `dart test`, `dart analyze` |
| `apps/finance_app` | Flutter client (iOS, Android, Windows, macOS, Linux) | `flutter test`, `flutter test test/unit/app_state_test.dart`, `flutter analyze`, `flutter run -d linux` |
| `server/finance-core`, `server/app` | Java 25 / Spring Boot 4.1 sync service (Gradle subprojects) | `gradle25w build`, `gradle25w :server:app:test --tests '*SyncCommands*'`, `SPRING_PROFILES_ACTIVE=local gradle25w :server:app:bootRun` |
| `spec/fixtures/*.json` | Golden fixtures run by both the Dart and Java test suites | change a rule here first |
| `spec/sync/protocol.md` | Client/server sync contract | |
| `tool/e2e/run.sh` | End-to-end suite: throwaway PostgreSQL and MinIO containers, the server's `e2e` profile, then `packages/finance_store/test/e2e` | `tool/e2e/run.sh` (`CONTAINER_ENGINE=docker` to use Docker, `FINANCE_E2E_SKIP_BUILD=1` to reuse the boot jar) |
| `.github/workflows` | `ci.yml` (all tests, server build, e2e), `build.yml` (all five platforms), `release.yml` (signing/notarisation from secrets) | run on GitHub Actions only |
| `src/docs` | Antora documentation | `gradle25w antora` |

Always use `gradle25w`, never `./gradlew`. Server integration tests use Testcontainers through the Podman socket (configured in the Gradle `test` task). `flutter test | tail` hides failures: write test output to a file and check the exit code. Run every package's tests after merging changes from another package: a new export in `finance_core` can clash with names in `finance_store` or Flutter (for example `Split` clashes with Flutter's animation `Split`; hide one).

## Architecture

- **Clients:** Flutter for iOS, Android, Windows, macOS and Linux. Dart packages organised by domain (accounts/ledger, budgeting, planning, receipts, imports, sync, reporting), with UI, business rules, persistence and platform services kept separate. State lives in an `AppState` `ChangeNotifier` exposed through `AppScope` (an `InheritedNotifier`); Riverpod and Drift were proposed in the PRD but not adopted.
- **Local storage:** `finance_store` — SQLite3MultipleCiphers database plus an AES-GCM receipt vault; the data key is held in the platform key store or wrapped with an Argon2id password. Every user action and its outbox command are saved in one transaction (`SYNC 01`). Typed tables hold accounts, categories, journals and postings; every other entity type (budget plans, schedules, receipts, rules…) is stored generically as JSON via `upsertEntity` and synced as `entity.upsert` with field-level revisions. The app's entity type names are in `apps/finance_app/lib/data/entity_types.dart` and `receipt_service.dart`/`import_service.dart`.
- **Backend (optional sync):** Java/Spring Boot modular monolith (Quarkus is an allowed substitute, but never both), PostgreSQL with Liquibase, S3-compatible private object storage, and a background worker deployed from the same codebase. REST + OpenAPI with versioned command envelopes; no GraphQL mutations.
- **Platform services** sit behind interfaces (`ReceiptScanner`, `TextRecognizer`, `SecureKeyStore`, `FileImporter`, `ShareInbox`, `Notifications`, `BackgroundScheduler`). Do not scatter platform conditionals through finance code. Layouts are driven by width breakpoints (compact < 600, medium 600–1023, expanded ≥ 1024), not by OS checks.
- Only the Linux desktop build and the Android APK can be produced on this development machine; iOS, macOS and Windows builds run on their own operating systems in CI (the iOS share extension target is added by `apps/finance_app/ios/tool/add_share_extension.rb`).
- Entity ids that reach the server must be UUIDs: use `newId()`, or `ownedEntityId`/`nameBasedId` for entities derived from another id. Device-local settings (such as `sync-settings.json`) are files, not synced entities.
- P1 server modules: `households` (invitations, roles, per-account `sharing`), `reports`, `audit`, `ops`, `extraction` (consented cloud text, untrusted, pre-fills drafts only) and `bankfeeds` (provider adapter boundary; only the `sandbox` provider exists until the Consumer Data Right provider is chosen). The app reaches them through `HouseholdClient`, `BankFeedClient` and `ExtractionClient` in `finance_store`.

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
