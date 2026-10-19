import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

/// Encodes to a JSON string and back, as the store and server will.
Map<String, Object?> wire(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  test('CSV mappings round-trip with header and index columns', () {
    final mapping = CsvMapping(
      id: 'm1',
      name: 'Card',
      accountId: 'card',
      dateColumn: const CsvColumn.header('Date'),
      dateFormat: 'yyyy-MM-dd',
      descriptionColumn: const CsvColumn.index(1),
      debitColumn: const CsvColumn.header('Debit'),
      creditColumn: const CsvColumn.header('Credit'),
      referenceColumn: const CsvColumn.header('Ref'),
      debitSign: DebitSign.positive,
      currencyCode: 'AUD',
      delimiter: ';',
      encoding: TextEncoding.windows1252,
      decimalSeparator: ',',
    );
    final json = csvMappingToJson(mapping);
    expect(json['dateColumn'], 'Date');
    expect(json['descriptionColumn'], 1);
    expect(json['amountColumn'], isNull);
    expect(json['encoding'], 'windows1252');
    expect(csvMappingToJson(csvMappingFromJson(wire(json))), json);
  });

  test('CSV mapping JSON applies documented defaults', () {
    final mapping = csvMappingFromJson({
      'id': 'm',
      'name': 'Minimal',
      'accountId': 'bank',
      'dateColumn': 0,
      'descriptionColumn': 1,
      'amountColumn': 2,
      'hasHeader': false,
    });
    expect(mapping.dateFormat, 'dd/MM/yyyy');
    expect(mapping.delimiter, ',');
    expect(mapping.decimalSeparator, '.');
    expect(mapping.debitSign, DebitSign.negative);
    expect(mapping.encoding, TextEncoding.utf8);
    expect(mapping.currencyCode, 'AUD');
  });
}
