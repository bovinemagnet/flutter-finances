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
  'pdf.inspect': _pdfInspect,
  'ofx.parse': _ofxParse,
  'qif.parse': _qifParse,
};

void _pdfInspect(Map<String, dynamic> input, Map<String, dynamic> expected) {
  final info = inspectPdf(
    Uint8List.fromList(base64.decode(input['base64'] as String)),
  );
  expect({
    'readable': info.readable,
    'encrypted': info.encrypted,
    'pageCount': info.pageCount,
  }, expected);
}

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

List<Map<String, Object?>> _rows(CsvParseResult result) => [
  for (final row in result.rows)
    {
      'row': row.rowNumber,
      'date': row.date.toString(),
      'amountMinor': row.amount.minor,
      'description': row.description,
      if (row.reference != null) 'reference': row.reference,
    },
];

List<Map<String, Object?>> _errors(CsvParseResult result) => [
  for (final error in result.errors)
    {'row': error.row, 'code': error.code.code},
];

/// Compares the keys present in [expected] only.
void _expectKeys(Map<String, Object?> actual, Map<String, dynamic> expected) {
  expect({for (final key in expected.keys) key: actual[key]}, expected);
}

void _ofxParse(Map<String, dynamic> input, Map<String, dynamic> expected) {
  final currency = Currency('AUD', input['exponent'] as int? ?? 2);
  final result = parseOfx(
    input['text'] as String,
    currency,
    accountId: input['accountId'] as String?,
  );
  _expectKeys({
    'accountId': result.accountId,
    'bankId': result.bankId,
    'accountType': result.accountType,
    'isCreditCard': result.isCreditCard,
    'currency': result.currencyCode,
    'ledgerBalanceMinor': result.ledgerBalance?.minor,
    'ledgerBalanceDate': result.ledgerBalanceDate?.toString(),
    'statementStart': result.statementStart?.toString(),
    'statementEnd': result.statementEnd?.toString(),
    'otherAccountIds': result.otherAccountIds,
    'rows': _rows(result),
    'errors': _errors(result),
  }, expected);
}

void _qifParse(Map<String, dynamic> input, Map<String, dynamic> expected) {
  final currency = Currency('AUD', input['exponent'] as int? ?? 2);
  final result = parseQif(
    input['text'] as String,
    currency,
    dateConvention: DateConvention.values.byName(
      input['dateConvention'] as String? ?? 'dayMonth',
    ),
    decimalSeparator: input['decimalSeparator'] as String? ?? '.',
  );
  _expectKeys({
    'accountType': result.accountType,
    'rows': _rows(result),
    'errors': _errors(result),
  }, expected);
}
