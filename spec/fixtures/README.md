# Shared financial fixtures

These JSON files are the executable contract between the Dart client
(`packages/finance_core/test/fixtures`) and the Java server
(`server/finance-core`). Both runners load every `*.json` file here and fail
on any operation they do not implement. Change a rule by changing a fixture
first.

Each file has `schemaVersion` (currently `1`), an `area`, and `cases`, each
with a unique `id`, an `op`, an `input` and an `expect` object. Amounts in
`ledger.scenario` and planning operations are decimal strings parsed with the
case's currency exponent; `money.*` and `journal.validate` use integer minor
units.

## Operations

`money.parse`
: Parses `text` with `exponent` and optional `decimalSeparator` (default
  `.`; the other of `.`/`,` is a grouping separator). Returns `minor`, or
  `error` `FORMAT` for malformed text or excess precision, `OUT_OF_RANGE`
  beyond 999,999,999,999,999 minor units.

`money.allocate`
: Splits integer `total` by non-negative integer `weights` with the largest
  remainder method on the magnitude; ties go to the lower index and the sign
  is reapplied afterwards.

`journal.validate`
: Returns the set of error codes: `EMPTY` (no postings, nothing else
  reported), `TOO_FEW_POSTINGS`, `MIXED_CURRENCY` (stops further checks),
  `UNBALANCED`, `ZERO_AMOUNT`, `OUT_OF_RANGE` (a posting or the total of
  debits exceeds the maximum magnitude).

`ledger.scenario`
: Builds accounts, categories and entries, then checks user-facing
  balances, net worth, journal count, draft errors and period totals. Entry
  validation runs in this order and reports the first failure:
  1. `UNKNOWN_ACCOUNT` for `account`; currency must match the workspace.
  2. Transfers: `UNKNOWN_ACCOUNT` for `to`, then `SAME_ACCOUNT`.
  3. `NON_POSITIVE_AMOUNT` (opening balances and adjustments only reject
     zero, because they are signed).
  4. Categorised entries (expense, income, refund, reimbursement with
     splits): `MISSING_SPLITS`, then per split `UNKNOWN_CATEGORY`,
     `WRONG_CATEGORY_KIND`, `NON_POSITIVE_AMOUNT`, then `SPLIT_MISMATCH`.

## Ledger conventions

- Debits are positive. User accounts and categories post to ledger accounts
  with the same identifier; system accounts use fixed identifiers such as
  `system:opening-equity`.
- Posted and reversed journals form the posted ledger. Pending journals only
  appear in pending views. Drafts are ignored.
- A correction posts a reversal on the original effective date plus a
  replacement, and marks the original `reversed`.
- Net worth sums ledger balances of accounts included in net worth plus the
  reimbursement receivable.
