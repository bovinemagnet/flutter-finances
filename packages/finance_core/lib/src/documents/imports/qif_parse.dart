import 'dart:typed_data';

import '../../money/money.dart';
import '../../time/local_date.dart';
import '../extraction/receipt_dates.dart';
import 'csv_parse.dart';
import 'import_errors.dart';
import 'ofx_parse.dart';
import 'text_decoding.dart';

/// Transactions read from a QIF file. It is a [CsvParseResult], so its rows
/// flow through `previewImport` and `commitImport` exactly as CSV rows do.
class QifParseResult extends CsvParseResult {
  QifParseResult(super.rows, super.errors, {this.accountType});

  /// The first transaction section's type as printed, such as `Bank` or
  /// `CCard`.
  final String? accountType;
}

/// Section types whose records are account transactions.
const _transactionTypes = {'bank', 'ccard', 'cash', 'oth a', 'oth l'};

/// Decodes QIF [bytes] (UTF-8 when valid, otherwise Windows-1252) and
/// parses them with [parseQif].
QifParseResult parseQifBytes(
  Uint8List bytes,
  Currency currency, {
  DateConvention dateConvention = DateConvention.dayMonth,
  String decimalSeparator = '.',
}) => parseQif(
  decodeText(bytes, detectEncoding(bytes)),
  currency,
  dateConvention: dateConvention,
  decimalSeparator: decimalSeparator,
);

/// Parses a Quicken Interchange Format file (IMP 01, P1).
///
/// Records in `!Type:Bank`, `!Type:CCard`, `!Type:Cash`, `!Type:Oth A` and
/// `!Type:Oth L` sections are transactions; other sections (`!Account`,
/// `!Type:Cat`, `!Type:Invst`, ...) are skipped, and `!Option:` and
/// `!Clear:` lines change nothing. Each record ends at a `^` line (or the
/// end of the file) and becomes an [ImportRow]:
///
/// - `rowNumber` is the record's 1-based position among transaction
///   records.
/// - `date` is the `D` line read with [parseQifDate] and [dateConvention].
/// - `amount` is the `T` line, or `U` when there is no `T`, read like a
///   CSV amount cell with [decimalSeparator]. It is signed from the
///   account's point of view (negative is money leaving, including card
///   charges).
/// - `description` is `P` followed by ` - M` as for OFX names and memos.
/// - `reference` is always null: QIF has no provider identifier (the `N`
///   line holds cheque numbers or words such as `ATM`), so fingerprints
///   use date, amount and description (IMP 02).
/// - `raw` is the record's lines as read, without the `^`.
///
/// Errors, at most one per record and in this order: `MISSING_FIELD` (no
/// `D` line), `BAD_DATE`, `BAD_AMOUNT`, `MISSING_AMOUNT`, `ZERO_AMOUNT`. A
/// file without a transaction section reports `UNRECOGNISED_FORMAT` on
/// row 0.
QifParseResult parseQif(
  String text,
  Currency currency, {
  DateConvention dateConvention = DateConvention.dayMonth,
  String decimalSeparator = '.',
}) {
  final body = text.startsWith('﻿') ? text.substring(1) : text;
  final rows = <ImportRow>[];
  final errors = <ImportRowError>[];
  String? accountType;
  var inTransactions = false;
  var number = 0;
  var record = <String>[];

  void finish() {
    if (!inTransactions || record.isEmpty) {
      record = [];
      return;
    }
    number++;
    final lines = record;
    record = [];
    void fail(ImportErrorCode code, String message) =>
        errors.add(ImportRowError(number, code, message));
    String? field(String code) {
      for (final line in lines) {
        if (line.startsWith(code)) return line.substring(1).trim();
      }
      return null;
    }

    final dateText = field('D');
    if (dateText == null) {
      fail(ImportErrorCode.missingField, 'The record has no date line');
      return;
    }
    final date = parseQifDate(dateText, dateConvention);
    if (date == null) {
      fail(ImportErrorCode.badDate, '"$dateText" is not a date');
      return;
    }
    final amountText = field('T') ?? field('U');
    final amount = amountText == null
        ? null
        : parseCsvAmount(
            amountText,
            currency.exponent,
            decimalSeparator: decimalSeparator,
          );
    if (amount != null && amount.isBad) {
      fail(ImportErrorCode.badAmount, '"$amountText" is not an amount');
      return;
    }
    if (amount?.minor == null) {
      fail(ImportErrorCode.missingAmount, 'The record has no amount');
      return;
    }
    if (amount!.minor == 0) {
      fail(ImportErrorCode.zeroAmount, 'The amount is zero');
      return;
    }
    rows.add(
      ImportRow(
        rowNumber: number,
        date: date,
        amount: Money(amount.minor!, currency),
        description: joinNameAndMemo(field('P'), field('M')),
        raw: lines,
      ),
    );
  }

  for (final line in body.split(RegExp(r'\r\n|\r|\n'))) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('!')) {
      final header = trimmed.toLowerCase();
      if (header.startsWith('!option:') || header.startsWith('!clear:')) {
        continue;
      }
      finish();
      final type = header.startsWith('!type:')
          ? header.substring(6).trim()
          : null;
      inTransactions = type != null && _transactionTypes.contains(type);
      if (inTransactions) accountType ??= trimmed.substring(6).trim();
      continue;
    }
    if (trimmed.startsWith('^')) {
      finish();
      continue;
    }
    record.add(trimmed);
  }
  finish();
  if (accountType == null) {
    return QifParseResult(const [], [
      const ImportRowError(
        0,
        ImportErrorCode.unrecognisedFormat,
        'The file is not a QIF statement',
      ),
    ]);
  }
  return QifParseResult(rows, errors, accountType: accountType);
}

final _isoDate = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$');
final _qifDate = RegExp(r"^(\d{1,2})[/.\-](\d{1,2})(['/.\-])(\d{1,4})$");

/// Reads a QIF date. Spaces are ignored (`1/ 9' 5` is `1/9'5`).
///
/// - `yyyy-mm-dd` (also with `/` or `.`) is always year, month, day.
/// - Otherwise `a/b/y` with `/`, `-` or `.` separators, where
///   [convention] decides whether `a` is the day or the month.
/// - An apostrophe before the year (`10/19'26`) marks a year from 2000:
///   one or two digits are added to 2000. Elsewhere a two-digit year below
///   70 is 20yy and from 70 is 19yy; four digits are taken as written.
///
/// Returns null when the text is not such a date or the date does not
/// exist.
LocalDate? parseQifDate(String text, DateConvention convention) {
  final t = text.replaceAll(' ', '');
  int? year;
  int? month;
  int? day;
  final iso = _isoDate.firstMatch(t);
  if (iso != null) {
    year = int.parse(iso[1]!);
    month = int.parse(iso[2]!);
    day = int.parse(iso[3]!);
  } else {
    final match = _qifDate.firstMatch(t);
    if (match == null) return null;
    final a = int.parse(match[1]!);
    final b = int.parse(match[2]!);
    final digits = match[4]!;
    final y = int.parse(digits);
    if (match[3] == "'") {
      year = digits.length <= 2 ? 2000 + y : (digits.length == 4 ? y : null);
    } else {
      year = switch (digits.length) {
        2 => y < 70 ? 2000 + y : 1900 + y,
        4 => y,
        _ => null,
      };
    }
    (day, month) = convention == DateConvention.dayMonth ? (a, b) : (b, a);
  }
  if (year == null || month < 1 || month > 12 || day < 1) return null;
  if (day > LocalDate.daysInMonth(year, month)) return null;
  return LocalDate(year, month, day);
}

/// Suggests how to read the file's numeric dates: [DateConvention.dayMonth]
/// when some `D` line can only be day first (its first part is above 12),
/// [DateConvention.monthDay] when some can only be month first, and null
/// when no date decides it or the dates disagree.
DateConvention? detectQifDateConvention(String text) {
  var dayFirst = false;
  var monthFirst = false;
  for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
    if (!line.startsWith('D')) continue;
    final match = _qifDate.firstMatch(line.substring(1).replaceAll(' ', ''));
    if (match == null) continue;
    if (int.parse(match[1]!) > 12) dayFirst = true;
    if (int.parse(match[2]!) > 12) monthFirst = true;
  }
  if (dayFirst == monthFirst) return null;
  return dayFirst ? DateConvention.dayMonth : DateConvention.monthDay;
}
