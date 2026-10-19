import 'csv_mapping.dart';
import 'text_decoding.dart';

/// JSON formats for import entities, shared with the server.

Map<String, Object?> csvMappingToJson(CsvMapping mapping) => {
  'id': mapping.id,
  'name': mapping.name,
  'accountId': mapping.accountId,
  'currency': mapping.currencyCode,
  'hasHeader': mapping.hasHeader,
  'delimiter': mapping.delimiter,
  'encoding': mapping.encoding.name,
  'decimalSeparator': mapping.decimalSeparator,
  'dateColumn': mapping.dateColumn.toJson(),
  'dateFormat': mapping.dateFormat,
  'descriptionColumn': mapping.descriptionColumn.toJson(),
  'amountColumn': mapping.amountColumn?.toJson(),
  'debitColumn': mapping.debitColumn?.toJson(),
  'creditColumn': mapping.creditColumn?.toJson(),
  'debitSign': mapping.debitSign.name,
  'referenceColumn': mapping.referenceColumn?.toJson(),
};

CsvColumn? _column(Object? json) =>
    json == null ? null : CsvColumn.fromJson(json);

/// Reads a mapping; omitted settings take the defaults of [CsvMapping].
CsvMapping csvMappingFromJson(Map<String, Object?> json) => CsvMapping(
  id: json['id'] as String,
  name: json['name'] as String? ?? '',
  accountId: json['accountId'] as String,
  currencyCode: json['currency'] as String? ?? 'AUD',
  hasHeader: json['hasHeader'] as bool? ?? true,
  delimiter: json['delimiter'] as String? ?? ',',
  encoding: TextEncoding.values.byName(json['encoding'] as String? ?? 'utf8'),
  decimalSeparator: json['decimalSeparator'] as String? ?? '.',
  dateColumn: CsvColumn.fromJson(json['dateColumn']!),
  dateFormat: json['dateFormat'] as String? ?? 'dd/MM/yyyy',
  descriptionColumn: CsvColumn.fromJson(json['descriptionColumn']!),
  amountColumn: _column(json['amountColumn']),
  debitColumn: _column(json['debitColumn']),
  creditColumn: _column(json['creditColumn']),
  debitSign: DebitSign.values.byName(
    json['debitSign'] as String? ?? 'negative',
  ),
  referenceColumn: _column(json['referenceColumn']),
);
