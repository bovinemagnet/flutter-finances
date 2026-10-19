import 'package:meta/meta.dart';

import '../matching/deduplication.dart';

enum ImportBatchStatus { committed, rolledBack }

/// One committed import of a statement file (IMP 02). Its rows live on as
/// [SourceRecord]s, separate from the journals they produced.
@immutable
class ImportBatch {
  const ImportBatch({
    required this.id,
    required this.accountId,
    required this.sourceHash,
    required this.importedAt,
    required this.rowCount,
    this.errorCount = 0,
    this.mappingId,
    this.fileName,
    this.status = ImportBatchStatus.committed,
    this.rolledBackAt,
  });

  final String id;
  final String accountId;

  /// SHA-256 of the raw file bytes; the same file is never committed twice
  /// (A12).
  final String sourceHash;

  /// When the batch was committed (UTC).
  final DateTime importedAt;
  final int rowCount;
  final int errorCount;
  final String? mappingId;
  final String? fileName;
  final ImportBatchStatus status;
  final DateTime? rolledBackAt;

  ImportBatch rolledBack(DateTime at) => ImportBatch(
    id: id,
    accountId: accountId,
    sourceHash: sourceHash,
    importedAt: importedAt,
    rowCount: rowCount,
    errorCount: errorCount,
    mappingId: mappingId,
    fileName: fileName,
    status: ImportBatchStatus.rolledBack,
    rolledBackAt: at.toUtc(),
  );
}

/// The source hash of an import file: lower-case hexadecimal SHA-256.
String sourceHashOf(List<int> bytes) => sha256Hex(bytes);
