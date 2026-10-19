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

## Planning operations

Cases live in `planning.json`. Unless stated otherwise:

- Money is a decimal string parsed with the case currency: `currency`
  (default `AUD`) and `exponent` (default `2`). Expected money is the
  canonical decimal string with exactly `exponent` fraction digits and a
  leading `-` when negative (`-0.07`, `0.00`).
- Dates are `YYYY-MM-DD` local dates. Every range and period end is
  inclusive.
- Rounding is always half away from zero on the exact rational result
  (Java `RoundingMode.HALF_UP`), computed without overflow.
- Exact splits use `money.allocate` (largest remainder, ties to the lower
  index).

### Repeat rules (shared by several operations)

A repeat has `frequency` (`daily`, `weekly`, `fortnightly`, `monthly`,
`quarterly`, `annually`), `interval` (default 1, at least 1), `start`,
optional `until` (inclusive), optional `count`, optional `endOfMonth`
(`clamp`, default, or `lastDay`) and optional `dayOfMonth` (default the
start's day).

Occurrence `n` (n ≥ 0) is computed from `start`, never from the previous
occurrence:

- Day-based: `start + n × interval × days`, where days is 1, 7 or 14.
- Month-based: move `n × interval × months` calendar months from `start`
  (months is 1, 3 or 12). With `clamp`, use `dayOfMonth`, or the last day of
  the target month when it is shorter (31 January gives 28 or 29 February
  and then 31 March). With `lastDay`, always use the last day of the target
  month; `start` must itself be a month end.
- `dayOfMonth` lets a continued series start on a clamped date (28 February)
  while keeping the intended day 31. `start` must equal the clamped
  `dayOfMonth` in its own month, otherwise the rule is invalid.

An occurrence exists while `n < count` and its date is on or before
`until`; the first one to fail ends the series.

### `periods.generate`

Input `{cycle, anchor, count, lengthDays?, endOfMonth?}`; output
`{periods: [{start, end}]}`.

Period starts are the repeat from `anchor` with `month` → monthly,
`week` → weekly, `fortnight` → fortnightly, `custom` → daily with
`interval = lengthDays` (required, positive). Period `i` runs from start `i`
to the day before start `i + 1`, so periods are contiguous and never
overlap. A month is never four weeks: monthly periods from 31 January run
31 Jan–27 Feb, 28 Feb–30 Mar, 31 Mar–29 Apr (A14). Return the first `count`
periods beginning at the anchor.

### `schedule.occurrences`

Input is a repeat rule; output `{dates: [...]}` listing every occurrence.
Output `{error: "UNBOUNDED"}` when neither `until` nor `count` is given and
`{error: "INVALID"}` when the rule is invalid (interval below 1, `lastDay`
without a month-end start, or a `dayOfMonth` that does not match `start`).

### `budget.remaining`

Input `{planned, rollover, adjustments, postedNet, pending}`; output
`{remaining, remainingAfterPending}` where

- `remaining = planned + rollover + adjustments − postedNet`
- `remainingAfterPending = remaining − pending`

`postedNet` and `pending` are signed so that spending is positive and
refunds reduce them. Only approved adjustments are ever passed in.

### `rollover.next`

Input `{policy, remaining}`; output `{opening}` for the next period:
`none` → `0`; `positiveOnly` → `max(remaining, 0)`; `signed` →
`remaining`.

### `allocation.template`

Input `{income, weights, groups}` where `weights[i]` is the basis-point
share (10000 = 100%) of group `groups[i]`. Output
`{amounts: {group: amount}, unassigned}`:

1. `shareTotal = Σ weights`.
2. `groupTotal = round(income × shareTotal ÷ 10000)` (half away from zero).
3. `amounts = money.allocate(groupTotal, weights)` (all zero when
   `shareTotal` is 0).
4. `unassigned = income − groupTotal`; negative means the shares exceed 100%
   and the plan is over-allocated by its magnitude.

### `monthly.equivalent`

Input `{amount, frequency, interval?}`; output
`{amount, annualFactor, isEstimate}`. Annual occurrences are daily 365,
weekly 52, fortnightly 26, monthly 12, quarterly 4, annually 1. With
`numerator` that figure and `denominator = 12 × interval`, the result is
`round(amount × numerator ÷ denominator)`, `annualFactor` is the string
`"numerator/denominator"` and `isEstimate` is `numerator ≠ denominator`.

### Planning scenario input (`forecast.daily`, `discretionary.estimate`)

- `today`: the workspace's local date.
- `accounts`: `{id, type, includeInForecast? (default true), balance?,
  dataAsOf?}`. `type` is a ledger account type (`transaction`, `savings`,
  `cash`, `creditCard`, `loan`, `property`, ...). `balance` is posted as an
  opening balance effective on `today` (money held, or owed for
  liabilities). `dataAsOf` is the date the account's data is known to be
  complete to.
- `categories`: `{id, kind? (expense default, or income)}`.
- `entries`: `{id, type, account, to?, category?, amount, date, status?}`
  with the `ledger.scenario` meanings; `category` is a single split of the
  whole amount; `status` defaults to `posted`.
- `schedules`: a repeat rule plus `{id, kind, account, to?, category?,
  amount, estimate?, confirmed? (default true)}`. `kind` is `expense`,
  `income` or `transfer` (`to` required, different from `account`).
- `overrides`: `{schedule, originalDate, dueDate?, amount?, skipped?}`
  ("this occurrence" edits). An override whose `originalDate` is not an
  occurrence is ignored. A moved occurrence is included where its `dueDate`
  falls.
- `payments`: `{schedule, occurrence (original date), journal, amount,
  settles?}` links an occurrence to the entry that paid it.
- `reservations`: `{id, goal?, account, amount, confirmed? (default true)}`.

**Eligible cash accounts** are accounts with `includeInForecast` true,
not archived, and of a liquid type (`transaction`, `savings`, `cash`).
Credit cards, loans, property, investments and superannuation never count.

**Occurrence outstanding amount.** A payment link counts only when its
journal exists with status `posted` or `pending`. `paid` is the sum of
counted links. The occurrence is settled when it is skipped, when
`paid ≥ amount`, or when any counted link has `settles: true`; then
outstanding is 0. Otherwise outstanding is `max(amount − paid, 0)`, where
`amount` is the override amount when set, else the schedule amount.

### `forecast.daily`

Extra input: `horizonDays` (default 90) and `scenario`, a list of changes:
`{type: "oneOff", id, date, account, amount (signed)}`,
`{type: "scheduleAmount", id, schedule, amount}` (project that schedule
at a new amount; an override amount still wins) and
`{type: "removeSchedule", id, schedule}`.

The forecast covers `today` to `today + horizonDays − 1` inclusive.

1. **Opening balance**: Σ over eligible accounts of postings in journals
   with status `posted` or `reversed` dated on or before `today`.
2. **Actual lines** (no other effect on the opening): each posted or
   reversed journal dated after `today` and within the horizon adds its net
   postings to each eligible account on its date; each `pending` journal
   dated on or before the horizon end adds its net eligible postings on
   `max(date, today)`. Drafts are ignored. A pending entry that becomes
   posted is therefore counted once.
3. **Committed lines**: each confirmed reservation in an eligible account
   subtracts its amount on `today` (reservations in excluded accounts are
   ignored; unconfirmed ones too). For each confirmed, non-removed schedule
   and each non-skipped occurrence whose due date is within the horizon,
   the outstanding amount applies on the due date: `expense` subtracts from
   `account`; `income` adds to `account`; `transfer` subtracts from
   `account` and adds to `to`. Only the eligible side(s) produce lines.
   Unconfirmed schedules are left out. A paid occurrence has outstanding 0,
   so a paid bill leaves one cash effect: its journal (A13).
4. **Hypothetical lines**: occurrences of schedules changed by
   `scheduleAmount` are tagged hypothetical instead of committed; `oneOff`
   changes for eligible accounts within the horizon add a hypothetical line.
5. Each day's closing = previous closing (opening balance for the first
   day) + that day's lines.

Expected output: `openingBalance`; `lowestBalance` (minimum closing over all
days, the first day included) and `lowestDate` (the earliest day with that
minimum); optional `days` (`{date: closing}`) and `certaintyTotals` (sum of
line amounts per `actual`, `committed`, `hypothetical`). The day count must
equal `horizonDays`.

### `discretionary.estimate`

Extra input: `horizonEnd` (inclusive; normally the day before the next
selected payday), `buffer` (minimum buffer, optional), `staleAfterDays`
(default 3), and an optional `budget`:
`{cycle, anchor, lengthDays?, income, groups: [{id, share,
discretionary?}], allocations: [{category, planned, group}]}`, a single plan
version effective from `anchor` with no rollover.

Output `{budgetLimit, cashLimit, estimate, shortfall, complete}` and,
when present in the case, `missingInputs` and `lowestDate`.

1. **Cash limit**: run `forecast.daily` from `today` to `horizonEnd` with
   no scenario; `cashLimit = lowestBalance − buffer` (buffer 0 when
   absent). Only confirmed income is projected, so income after the low
   point cannot raise the limit.
2. **Budget limit**: take the budget period containing `today`.
   Discretionary categories are the allocations in groups with
   `discretionary: true`. For each, posted net and pending are the category
   totals of `posted`/`reversed` and of `pending` journals dated inside the
   period (expense postings positive, refunds negative), regardless of the
   paying account, so pending card purchases count here but not in cash.
   `remainingAfterPending = planned − postedNet − pending`. Commitments are
   the outstanding amounts of confirmed `expense` schedule occurrences in
   those categories due from `today` to the earlier of `horizonEnd` and the
   period end. `budgetLimit = Σ remainingAfterPending − commitments`. With
   no budget, or no discretionary allocation, `budgetLimit` is `null` and
   `budget` is a missing input.
3. **Estimate**: `smaller = min(budgetLimit, cashLimit)` (just `cashLimit`
   when `budgetLimit` is null); `estimate = max(smaller, 0)`;
   `shortfall = max(−smaller, 0)`.
4. **Missing inputs**, in this order: `budget`; `minimumBuffer` when no
   buffer; then for each eligible account in ascending id order,
   `accountData:<id>` when it has no `dataAsOf`, or
   `staleAccountData:<id>` when `dataAsOf < today − staleAfterDays`.
   `complete` is true only when the list is empty.

The PRD worked example (`BUD07-prd-worked-example`): eligible cash $4,000;
commitments $1,050 + $150 = $1,200; pending $100; reservation $500 (an
$800 reservation in an excluded savings account is not subtracted); buffer
$500. The lowest balance is $2,200, so the cash limit is $1,700. Wants has
$950 − $250 − $100 = $600 for dining plus $150 − $150 commitment = $0 for
streaming, so the budget limit and estimate are $600.
