import 'package:meta/meta.dart';

import 'text_decoding.dart';

/// A column chosen by zero-based position or by header name.
@immutable
class CsvColumn {
  const CsvColumn.index(int this.index) : header = null;
  const CsvColumn.header(String this.header) : index = null;

  /// Reads `0` (an index) or `"Date"` (a header name).
  factory CsvColumn.fromJson(Object json) => switch (json) {
    int value => CsvColumn.index(value),
    String value => CsvColumn.header(value),
    _ => throw FormatException('Column must be an index or a header name'),
  };

  final int? index;
  final String? header;

  Object toJson() => index ?? header!;

  /// The field position in records, or null when the header lacks it.
  int? resolve(List<String>? headerRow) {
    if (index != null) return index;
    if (headerRow == null) return null;
    final wanted = header!.trim().toLowerCase();
    for (var i = 0; i < headerRow.length; i++) {
      if (headerRow[i].trim().toLowerCase() == wanted) return i;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CsvColumn && other.index == index && other.header == header;

  @override
  int get hashCode => Object.hash(index, header);

  @override
  String toString() => index?.toString() ?? '"$header"';
}

/// How a single signed amount column shows money leaving the account.
enum DebitSign {
  /// Debits (purchases, withdrawals) are negative, as most bank exports do.
  negative,

  /// Debits are positive, as many card statements do; signs are flipped.
  positive,
}

/// A saved CSV mapping template (IMP 01).
///
/// Exactly one amount layout is required: a signed [amountColumn], or both
/// [debitColumn] and [creditColumn]. Header-name columns need [hasHeader].
@immutable
class CsvMapping {
  CsvMapping({
    required this.id,
    required this.name,
    required this.accountId,
    required this.dateColumn,
    required this.descriptionColumn,
    this.dateFormat = 'dd/MM/yyyy',
    this.amountColumn,
    this.debitColumn,
    this.creditColumn,
    this.referenceColumn,
    this.debitSign = DebitSign.negative,
    this.currencyCode = 'AUD',
    this.delimiter = ',',
    this.encoding = TextEncoding.utf8,
    this.decimalSeparator = '.',
    this.hasHeader = true,
  }) {
    final signed = amountColumn != null;
    final split = debitColumn != null || creditColumn != null;
    if (signed == split) {
      throw ArgumentError(
        'Choose either a signed amount column or debit and credit columns',
      );
    }
    if (split && (debitColumn == null || creditColumn == null)) {
      throw ArgumentError('Both debit and credit columns are required');
    }
    if (delimiter.length != 1) {
      throw ArgumentError.value(delimiter, 'delimiter', 'one character');
    }
    if (decimalSeparator != '.' && decimalSeparator != ',') {
      throw ArgumentError.value(decimalSeparator, 'decimalSeparator');
    }
    final columns = [
      dateColumn,
      descriptionColumn,
      amountColumn,
      debitColumn,
      creditColumn,
      referenceColumn,
    ];
    if (!hasHeader && columns.any((c) => c?.header != null)) {
      throw ArgumentError('Header names need a file with a header row');
    }
  }

  final String id;
  final String name;

  /// The user account the rows belong to.
  final String accountId;
  final CsvColumn dateColumn;
  final String dateFormat;
  final CsvColumn descriptionColumn;
  final CsvColumn? amountColumn;
  final CsvColumn? debitColumn;
  final CsvColumn? creditColumn;
  final CsvColumn? referenceColumn;
  final DebitSign debitSign;
  final String currencyCode;
  final String delimiter;
  final TextEncoding encoding;
  final String decimalSeparator;
  final bool hasHeader;

  bool get usesSignedAmount => amountColumn != null;
}
