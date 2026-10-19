import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'ops.dart';

/// Fixture operations for receipts, imports and exports.
final Map<String, FixtureOp> documentsOps = {
  'csv.parse': _csvParse,
  'csv.fingerprint': _csvFingerprint,
  'csv.sanitise': _csvSanitise,
  'content.sniff': _contentSniff,
};

void _csvParse(Map<String, dynamic> input, Map<String, dynamic> expected) {
  final mapping = csvMappingFromJson(
    (input['mapping'] as Map).cast<String, Object?>(),
  );
  final currency = Currency(
    mapping.currencyCode,
    input['exponent'] as int? ?? 2,
  );
  final result = parseCsvRows(input['text'] as String, mapping, currency);
  expect([
    for (final row in result.rows)
      {
        'row': row.rowNumber,
        'date': row.date.toString(),
        'amountMinor': row.amount.minor,
        'description': row.description,
        if (row.reference != null) 'reference': row.reference,
      },
  ], expected['rows']);
  expect([
    for (final error in result.errors)
      {'row': error.row, 'code': error.code.code},
  ], expected['errors']);
}

void _csvFingerprint(
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
) {
  const currency = Currency.aud;
  final rows = [
    for (final (i, raw)
        in (input['rows'] as List).cast<Map<String, dynamic>>().indexed)
      ImportRow(
        rowNumber: i + 1,
        date: LocalDate.parse(raw['date'] as String),
        amount: Money(raw['amountMinor'] as int, currency),
        description: raw['description'] as String,
        reference: raw['reference'] as String?,
        raw: const [],
      ),
  ];
  expect(
    assignFingerprints(input['account'] as String, rows),
    expected['fingerprints'],
  );
}

void _csvSanitise(Map<String, dynamic> input, Map<String, dynamic> expected) {
  expect(sanitiseCsvValue(input['value'] as String), expected['value']);
}

void _contentSniff(Map<String, dynamic> input, Map<String, dynamic> expected) {
  final bytes = Uint8List.fromList(base64.decode(input['base64'] as String));
  final Map<String, Object?> actual;
  if (bytes.isEmpty) {
    actual = {'error': ContentErrorCode.emptyFile.code};
  } else {
    final type = sniffContentType(bytes);
    actual = type == null
        ? {'error': ContentErrorCode.unsupportedType.code}
        : {'contentType': type.mimeType};
  }
  expect(actual, expected);
}
