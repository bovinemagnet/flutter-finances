# P1 Increment and Release Engineering Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the PRD's P1 increment and the release engineering the P0 release still needs, on top of the completed P0 implementation.

**Architecture:** Same components as `2026-10-19-personal-finance-roadmap.md`. P1 domain rules go into `finance_core` (shared fixtures where the server also needs the rule), server capabilities into new or existing Spring Modulith modules, client UI into `apps/finance_app`. Release engineering lives in `.github/workflows`, `tool/packaging` and the platform folders.

**Spec:** `docs/prd/initial.md` (section 3 P1 column, sections 8, 13–17).

## Global Constraints

Identical to the roadmap. Additionally: entity ids that reach the server are UUIDs (owned entities use `ownedEntityId`/`nameBasedId`); never use last write wins; nothing financial happens without confirmation; bank feeds never ask for bank passwords.

## Tasks

### Server (P1 and operations)
- [x] S1 Report endpoints over canonical journals (REP 01) with the same definitions as the client
- [x] S2 Households: invitations, roles, explicit shared accounts and visibility filtering of the change feed (P1 shared households, SEC 05)
- [x] S3 Audit events with 12-month retention; storage lifecycle rules for staging uploads and exports (SEC 06)
- [x] S4 Metrics: extraction latency, backup success reporting and alerting hooks (operations)
- [x] S5 Optional cloud extraction behind consent and an isolated provider adapter (AUTO 02, P1)
- [x] S6 Bank feed adapter boundary: provider interface, consent records and health, webhook verification and deduplication, provider records kept separate, sandbox provider (BANK 01–03)

### Domain (P1)
- [x] D1 OFX and QIF import
- [x] D2 Subscription detection and anomaly detection insights
- [x] D3 Debt payoff comparisons and zero-based allocation mode
- [x] D4 Item-level receipt extraction, warranty reminders
- [x] D5 Detailed investment holdings
- [x] D6 Automatic separation of multi-receipt documents

### Release engineering
- [x] R1 CI: tests for every package, server build, end-to-end suite, builds for Android, iOS, macOS, Windows and Linux
- [x] R2 Release signing and notarisation driven by secrets; Linux package
- [x] R3 iOS share extension target and App Group handoff
- [x] R4 Render and check every Mermaid diagram (all nine render with the system Chrome)

### Client
- [x] C1 Wire household sharing, P1 insights, imports, debt, holdings, bank feed proposals and cloud extraction consent into the app

### Verification notes
- The iOS share extension script, the workflows and the macOS, Windows and iOS builds can only run on GitHub Actions runners; they are checked there, not locally.
- A real Consumer Data Right provider and a real cloud extraction provider remain pending business decisions (BANK 01, AUTO 02); only the sandbox and a configurable adapter exist.
