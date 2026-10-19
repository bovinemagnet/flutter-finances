import '../../money/money.dart';
import '../../time/local_date.dart';
import 'csv_mapping.dart';
import 'import_batch.dart';
import 'source_record.dart';
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

Map<String, Object?> importBatchToJson(ImportBatch batch) => {
  'id': batch.id,
  'accountId': batch.accountId,
  'sourceHash': batch.sourceHash,
  'importedAt': batch.importedAt.toUtc().toIso8601String(),
  'rowCount': batch.rowCount,
  'errorCount': batch.errorCount,
  'mappingId': batch.mappingId,
  'fileName': batch.fileName,
  'status': batch.status.name,
  'rolledBackAt': batch.rolledBackAt?.toUtc().toIso8601String(),
};

ImportBatch importBatchFromJson(Map<String, Object?> json) => ImportBatch(
  id: json['id'] as String,
  accountId: json['accountId'] as String,
  sourceHash: json['sourceHash'] as String,
  importedAt: DateTime.parse(json['importedAt'] as String).toUtc(),
  rowCount: json['rowCount'] as int,
  errorCount: json['errorCount'] as int? ?? 0,
  mappingId: json['mappingId'] as String?,
  fileName: json['fileName'] as String?,
  status: ImportBatchStatus.values.byName(
    json['status'] as String? ?? 'committed',
  ),
  rolledBackAt: json['rolledBackAt'] == null
      ? null
      : DateTime.parse(json['rolledBackAt'] as String).toUtc(),
);

Map<String, Object?> sourceRecordToJson(SourceRecord record) => {
  'id': record.id,
  'batchId': record.batchId,
  'accountId': record.accountId,
  'rowNumber': record.rowNumber,
  'fingerprint': record.fingerprint,
  'raw': record.raw,
  'date': record.date.toString(),
  'amountMinor': record.amount.minor,
  'currency': record.amount.currency.code,
  'description': record.description,
  'reference': record.reference,
  'pendingReference': record.pendingReference,
  'status': record.status.name,
  'decision': record.decision.name,
  'journalId': record.journalId,
  'rolledBack': record.rolledBack,
};

/// Reads a source record in the workspace [currency]; another currency is
/// rejected.
SourceRecord sourceRecordFromJson(
  Map<String, Object?> json,
  Currency currency,
) {
  final code = json['currency'] as String?;
  if (code != null && code != currency.code) {
    throw CurrencyMismatchException(
      currency,
      Currency(code, currency.exponent),
    );
  }
  return SourceRecord(
    id: json['id'] as String,
    batchId: json['batchId'] as String,
    accountId: json['accountId'] as String,
    rowNumber: json['rowNumber'] as int,
    fingerprint: json['fingerprint'] as String,
    raw: (json['raw'] as List).cast<String>(),
    date: LocalDate.parse(json['date'] as String),
    amount: Money(json['amountMinor'] as int, currency),
    description: json['description'] as String,
    reference: json['reference'] as String?,
    pendingReference: json['pendingReference'] as String?,
    status: SourceStatus.values.byName(json['status'] as String? ?? 'posted'),
    decision: SourceDecision.values.byName(json['decision'] as String),
    journalId: json['journalId'] as String?,
    rolledBack: json['rolledBack'] as bool? ?? false,
  );
}
