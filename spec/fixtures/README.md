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

## Documents operations

Cases live in `documents.json`. Amounts are integer minor units.

`csv.parse`
: Input `{text, mapping, exponent?}` (exponent defaults to 2). Output
  `{rows: [{row, date, amountMinor, description, reference?}], errors:
  [{row, code}]}`, both in file order (errors sorted by row).

  *Mapping JSON* (`CsvMapping`): `id`, `name`, `accountId`, `currency`
  (default `AUD`), `hasHeader` (default `true`), `delimiter` (one
  character, default `,`), `encoding` (`utf8`, `windows1252` or `latin1`,
  default `utf8`; used only when decoding bytes), `decimalSeparator` (`.`
  or `,`, default `.`), `dateColumn`, `dateFormat` (default `dd/MM/yyyy`),
  `descriptionColumn`, either `amountColumn` (signed) or both `debitColumn`
  and `creditColumn`, `debitSign` (`negative` or `positive`, default
  `negative`) and optional `referenceColumn`. A column is a zero-based
  integer index or a header name string; header names match after
  trimming whitespace, ignoring case, and need `hasHeader`.

  *Reading* follows RFC 4180: records end at CRLF, LF or CR outside
  quotes; a field that starts with `"` is quoted, `""` inside it is one
  quote, and delimiters and line breaks inside it are literal. A quote
  anywhere else (inside an unquoted field or after a closing quote up to
  the next delimiter) is kept literally. A leading U+FEFF is removed.
  `row` is the 1-based record number counting the header record and blank
  records; blank records (an empty line) are skipped silently. An
  unterminated quote reports `UNTERMINATED_QUOTE` at the record where the
  quote opened and stops reading; records before it are still parsed.

  *Header*: when a required column (date, description, amount, or debit
  and credit) is not in the header, the only output is
  `{row: 1, code: COLUMN_NOT_FOUND}` per missing column and no rows. A
  missing reference column, or a record too short to have it, gives no
  reference.

  *Each record* reports at most one error, checked in this order:
  1. `MISSING_FIELD` when the record has no field at a required column.
  2. `BAD_DATE` when the trimmed date does not match `dateFormat` or the
     date does not exist. Format tokens: `yyyy` four digits; `yy` two
     digits meaning 2000-2099; `MMM` an English three-letter month in any
     case; `MM` or `M` and `dd` or `d` one or two digits. Other characters
     match literally. Anything after whitespace following the date (a
     time) is ignored.
  3. Amount cells: trim; empty means no value; remove every `$` and space;
     `(x)` or a trailing `-` negates; then the `money.parse` rules apply
     with `decimalSeparator` (the other of `.` and `,` is grouping). Text
     that fails is `BAD_AMOUNT` (including too many decimal places).
     - Signed layout: no value is `MISSING_AMOUNT`; the amount is the
       value with `debitSign: negative`, or its negation with `positive`.
     - Debit/credit layout: `BAD_AMOUNT` if either cell fails; both empty
       is `MISSING_AMOUNT`; magnitudes are taken (`abs`) and both non-zero
       is `BOTH_DEBIT_AND_CREDIT`; the amount is `credit - debit`.
  4. `ZERO_AMOUNT` when the resulting amount is zero.

  The resulting amount is signed from the account's point of view:
  negative is money leaving the account. `description` and `reference`
  are trimmed; an empty reference is omitted.

`csv.fingerprint`
: Input `{account, rows: [{date, amountMinor, description, reference?}]}`.
  Output `{fingerprints: [...]}` in row order. The base of each row is
  `ref|<account>|<trimmed reference>` when the trimmed reference is
  non-empty, otherwise
  `fp|<account>|<YYYY-MM-DD>|<amountMinor>|<normalised description>`. The
  description is normalised by lower-casing, replacing every run of
  characters other than ASCII `a`-`z` and `0`-`9` with a single space, and
  trimming (non-ASCII letters become separators; an all-punctuation
  description normalises to the empty string). The fingerprint is the base
  plus `#` plus the 1-based occurrence of that base so far in the list, so
  two identical same-day purchases are `...#1` and `...#2` and both are
  kept (A11).

`csv.sanitise`
: Input `{value}`, output `{value}`. A value whose first character is `=`,
  `+`, `-`, `@`, tab or carriage return gets a leading `'`; anything else,
  including the empty string, is unchanged. Exports apply this to user
  text fields only; numeric amounts are written unsanitised.

`content.sniff`
: Input `{base64}`, output `{contentType}` or `{error}`. Only magic bytes
  count, never a name or claimed type. Zero bytes is `EMPTY_FILE`. Then:
  `FF D8 FF` at offset 0 is `image/jpeg`; the PNG signature
  `89 50 4E 47 0D 0A 1A 0A` at offset 0 is `image/png`; `ftyp` at offset 4
  makes the four bytes at offset 8 a brand, where `heic`, `heix`, `hevc`,
  `hevx`, `heim`, `heis`, `hevm`, `hevs` are `image/heic`, `mif1` and
  `msf1` are `image/heif` and any other brand is unsupported; `%PDF-`
  starting at any offset from 0 to 1024 is `application/pdf`. Everything
  else is `UNSUPPORTED_TYPE`.
