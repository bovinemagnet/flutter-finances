import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import 'csv_mapping.dart';
import 'csv_reader.dart';
import 'date_format.dart';
import 'import_errors.dart';
import 'text_decoding.dart';

/// One parsed statement row. [amount] is signed from the account's point
/// of view: negative is money leaving the account (a purchase, a
/// withdrawal, a card charge), positive is money arriving.
@immutable
class ImportRow {
  ImportRow({
    required this.rowNumber,
    required this.date,
    required this.amount,
    required this.description,
    required List<String> raw,
    this.reference,
  }) : raw = List.unmodifiable(raw);

  /// 1-based record number in the file, counting the header record.
  final int rowNumber;
  final LocalDate date;
  final Money amount;
  final String description;

  /// The bank or provider reference, when the file has one.
  final String? reference;

  /// The raw fields, preserved as evidence (IMP 02).
  final List<String> raw;
}

@immutable
class CsvParseResult {
  CsvParseResult(List<ImportRow> rows, List<ImportRowError> errors)
    : rows = List.unmodifiable(rows),
      errors = List.unmodifiable(errors);

  final List<ImportRow> rows;
  final List<ImportRowError> errors;
}

/// Decodes [bytes] with the mapping's encoding, then parses them.
CsvParseResult parseCsvBytes(
  Uint8List bytes,
  CsvMapping mapping,
  Currency currency,
) => parseCsvRows(decodeText(bytes, mapping.encoding), mapping, currency);

/// Parses CSV [text] into rows using [mapping] (IMP 01).
///
/// A leading U+FEFF is removed. Header names match case-insensitively
/// after trimming; descriptions and references are trimmed.
///
/// Each row reports at most one error, checked in this order:
/// `MISSING_FIELD` (a required column is beyond the end of the record),
/// `BAD_DATE`, then the amount: `BAD_AMOUNT`, `MISSING_AMOUNT`,
/// `BOTH_DEBIT_AND_CREDIT`, `ZERO_AMOUNT`. A missing header column is
/// `COLUMN_NOT_FOUND` on record 1 and nothing is parsed. The optional
/// reference column may be absent from the header or the record.
CsvParseResult parseCsvRows(
  String text,
  CsvMapping mapping,
  Currency currency,
) {
  // A byte order mark that survived decoding is not part of the header.
  final body = text.startsWith('﻿') ? text.substring(1) : text;
  final read = readCsv(body, delimiter: mapping.delimiter);
  final errors = <ImportRowError>[...read.errors];
  final rows = <ImportRow>[];
  var records = read.records;
  List<String>? header;
  if (mapping.hasHeader && records.isNotEmpty) {
    header = records.first.fields;
    records = records.sublist(1);
  }

  int? required(CsvColumn column, String label) {
    final index = column.resolve(header);
    if (index == null) {
      errors.add(
        ImportRowError(
          1,
          ImportErrorCode.columnNotFound,
          'The $label column $column is not in the header',
        ),
      );
    }
    return index;
  }

  final dateIndex = required(mapping.dateColumn, 'date');
  final descriptionIndex = required(mapping.descriptionColumn, 'description');
  final amountIndex = mapping.amountColumn == null
      ? null
      : required(mapping.amountColumn!, 'amount');
  final debitIndex = mapping.debitColumn == null
      ? null
      : required(mapping.debitColumn!, 'debit');
  final creditIndex = mapping.creditColumn == null
      ? null
      : required(mapping.creditColumn!, 'credit');
  final referenceIndex = mapping.referenceColumn?.resolve(header);
  if (errors.any((e) => e.code == ImportErrorCode.columnNotFound)) {
    return CsvParseResult(const [], errors);
  }
  final needed = [
    dateIndex!,
    descriptionIndex!,
    ?amountIndex,
    ?debitIndex,
    ?creditIndex,
  ].reduce((a, b) => a > b ? a : b);

  for (final record in records) {
    final fields = record.fields;
    void fail(ImportErrorCode code, String message) =>
        errors.add(ImportRowError(record.number, code, message));

    if (fields.length <= needed) {
      fail(ImportErrorCode.missingField, 'The row has too few columns');
      continue;
    }
    final dateText = fields[dateIndex];
    final date = parseDateWithFormat(dateText, mapping.dateFormat);
    if (date == null) {
      fail(
        ImportErrorCode.badDate,
        '"$dateText" is not a date in the format ${mapping.dateFormat}',
      );
      continue;
    }
    final amount = _rowAmount(
      fields,
      mapping,
      currency,
      amountIndex,
      debitIndex,
      creditIndex,
    );
    if (amount.error != null) {
      fail(amount.error!, amount.message!);
      continue;
    }
    final reference = referenceIndex != null && referenceIndex < fields.length
        ? fields[referenceIndex].trim()
        : '';
    rows.add(
      ImportRow(
        rowNumber: record.number,
        date: date,
        amount: Money(amount.minor!, currency),
        description: fields[descriptionIndex].trim(),
        reference: reference.isEmpty ? null : reference,
        raw: fields,
      ),
    );
  }
  errors.sort((a, b) => a.row.compareTo(b.row));
  return CsvParseResult(rows, errors);
}

typedef _Amount = ({int? minor, ImportErrorCode? error, String? message});

_Amount _rowAmount(
  List<String> fields,
  CsvMapping mapping,
  Currency currency,
  int? amountIndex,
  int? debitIndex,
  int? creditIndex,
) {
  _Amount failure(ImportErrorCode code, String message) =>
      (minor: null, error: code, message: message);

  int? value;
  if (amountIndex != null) {
    final text = fields[amountIndex];
    final parsed = parseCsvAmount(
      text,
      currency.exponent,
      decimalSeparator: mapping.decimalSeparator,
    );
    if (parsed.isBad) {
      return failure(ImportErrorCode.badAmount, '"$text" is not an amount');
    }
    if (parsed.minor == null) {
      return failure(ImportErrorCode.missingAmount, 'The amount is empty');
    }
    value = mapping.debitSign == DebitSign.negative
        ? parsed.minor
        : -parsed.minor!;
  } else {
    final debitText = fields[debitIndex!];
    final creditText = fields[creditIndex!];
    final debit = parseCsvAmount(
      debitText,
      currency.exponent,
      decimalSeparator: mapping.decimalSeparator,
    );
    final credit = parseCsvAmount(
      creditText,
      currency.exponent,
      decimalSeparator: mapping.decimalSeparator,
    );
    if (debit.isBad || credit.isBad) {
      final bad = debit.isBad ? debitText : creditText;
      return failure(ImportErrorCode.badAmount, '"$bad" is not an amount');
    }
    if (debit.minor == null && credit.minor == null) {
      return failure(
        ImportErrorCode.missingAmount,
        'Both the debit and credit columns are empty',
      );
    }
    final d = (debit.minor ?? 0).abs();
    final c = (credit.minor ?? 0).abs();
    if (d != 0 && c != 0) {
      return failure(
        ImportErrorCode.bothDebitAndCredit,
        'The row has both a debit and a credit',
      );
    }
    value = c - d;
  }
  if (value == 0) {
    return failure(ImportErrorCode.zeroAmount, 'The amount is zero');
  }
  return (minor: value, error: null, message: null);
}

/// The result of reading one amount cell.
typedef CsvAmount = ({int? minor, bool isBad});

/// Reads a CSV amount cell into minor units.
///
/// The text is trimmed; empty text is no amount (`minor` null). `$`
/// characters and spaces are removed, `(x)` and a trailing `-` mean
/// negative, then the rules of `money.parse` apply with
/// [decimalSeparator] (the other of `.` and `,` is a grouping separator).
CsvAmount parseCsvAmount(
  String text,
  int exponent, {
  String decimalSeparator = '.',
}) {
  var t = text.trim().replaceAll(r'$', '').replaceAll(' ', '');
  if (t.isEmpty) return (minor: null, isBad: false);
  var negate = false;
  if (t.length > 2 && t.startsWith('(') && t.endsWith(')')) {
    negate = true;
    t = t.substring(1, t.length - 1);
  } else if (t.length > 1 && t.endsWith('-')) {
    negate = true;
    t = t.substring(0, t.length - 1);
  }
  try {
    final minor = parseMinor(t, exponent, decimalSeparator: decimalSeparator);
    return (minor: negate ? -minor : minor, isBad: false);
  } on FormatException {
    return (minor: null, isBad: true);
  } on MoneyRangeException {
    return (minor: null, isBad: true);
  }
}
