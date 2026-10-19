# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

This repository is at the specification stage. The only content is the product requirements document at `docs/prd/initial.md`; there is no source code, build configuration, or test suite yet. Read the PRD before starting any feature work: requirement IDs (`FIN 03`, `REC 04`, `SYNC 02`, acceptance tests `A01`–`A18`, etc.) are the shared vocabulary for scope and tests.

When build tooling is added, record the build, lint, and single-test commands here. For any Gradle-based backend, use `gradle25w` rather than `./gradlew`.

## Planned architecture (from the PRD)

- **Clients:** Flutter for iOS, Android, Windows, macOS and Linux. Dart packages organised by domain (accounts/ledger, budgeting, planning, receipts, imports, sync, reporting), with UI, business rules, persistence and platform services kept separate. Riverpod and Drift are *proposed*, pending a prototype.
- **Local storage:** encrypted SQLite plus protected files. The client reads from its local database and writes user actions together with an outbox command in a single local transaction (`SYNC 01`).
- **Backend (optional sync):** Java/Spring Boot modular monolith (Quarkus is an allowed substitute, but never both), PostgreSQL with Liquibase, S3-compatible private object storage, and a background worker deployed from the same codebase. REST + OpenAPI with versioned command envelopes; no GraphQL mutations.
- **Platform services** sit behind interfaces (`ReceiptScanner`, `TextRecognizer`, `SecureKeyStore`, `FileImporter`, `ShareInbox`, `Notifications`, `BackgroundScheduler`). Do not scatter platform conditionals through finance code. Layouts are driven by width breakpoints (compact < 600, medium 600–1023, expanded ≥ 1024), not by OS checks.
- A **decision prototype** (PRD §10) is meant to precede feature development: offline receipt capture, DB encryption/key retrieval, PDF import, share-target handoff, two-device conflict, signed builds on all five OS families.

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
