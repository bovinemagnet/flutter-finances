import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';

import 'app_state.dart';

abstract final class ImportEntityTypes {
  static const mapping = 'csvMapping';
  static const batch = 'importBatch';
  static const sourceRecord = 'sourceRecord';
}

/// Fixed categories for imported rows the user has not categorised yet.
abstract final class UncategorisedIds {
  static const expense = 'uncategorised-expense';
  static const income = 'uncategorised-income';
}

enum StatementFormat { csv, ofx, qif }

/// Recognises OFX (`OFXHEADER` or an `<OFX>` element) and QIF (`!Type:`)
/// by content first and file name second; anything else is CSV.
StatementFormat detectStatementFormat(Uint8List bytes, String? fileName) {
  var head = String.fromCharCodes(bytes.take(512)).trimLeft().toUpperCase();
  if (head.startsWith('\u{FEFF}')) head = head.substring(1);
  if (head.startsWith('OFXHEADER') ||
      head.contains('<OFX>') ||
      (head.startsWith('<?XML') && head.contains('<OFX'))) {
    return StatementFormat.ofx;
  }
  if (head.startsWith('!TYPE:')) return StatementFormat.qif;
  final name = fileName?.toLowerCase() ?? '';
  if (name.endsWith('.ofx') || name.endsWith('.qfx')) {
    return StatementFormat.ofx;
  }
  if (name.endsWith('.qif')) return StatementFormat.qif;
  return StatementFormat.csv;
}

class ImportOutcome {
  const ImportOutcome(
    this.batch,
    this.posted, {
    required this.alreadyCommitted,
  });
  final ImportBatch batch;
  final int posted;
  final bool alreadyCommitted;
}

/// Bank statement import (IMP 01 to IMP 03). Raw rows and source hashes are
/// kept as provenance entities apart from the journals they create, and
/// every journal goes through the same command path as manual entry.
class ImportService {
  ImportService(this.state);
  final AppState state;

  List<T> _all<T>(String type, T Function(Map<String, Object?>) decode) => [
    for (final r in state.store.entities(type))
      if (!r.deleted) decode(r.json),
  ];

  List<CsvMapping> get mappings =>
      _all(ImportEntityTypes.mapping, csvMappingFromJson);
  List<ImportBatch> get batches =>
      _all(ImportEntityTypes.batch, importBatchFromJson);
  List<SourceRecord> get sourceRecords => _all(
    ImportEntityTypes.sourceRecord,
    (j) => sourceRecordFromJson(j, state.currency),
  );

  Future<void> saveMapping(CsvMapping mapping) async {
    await state.store.upsertEntity(
      ImportEntityTypes.mapping,
      mapping.id,
      csvMappingToJson(mapping),
    );
    state.refresh();
  }

  ImportPreview preview(Uint8List bytes, CsvMapping mapping) => previewImport(
    accountId: mapping.accountId,
    parsed: parseCsvBytes(bytes, mapping, state.currency),
    sourceHash: sourceHashOf(bytes),
    chart: state.chart,
    batches: batches,
    existingRecords: sourceRecords,
    journals: state.ledger.journals,
    receiptJournalIds: state.receipts.receiptJournalIds,
  );

  Future<void> _ensureUncategorised() async {
    if (!state.chart.hasCategory(UncategorisedIds.expense)) {
      await state.store.createCategory(
        const Category(
          id: UncategorisedIds.expense,
          name: 'Uncategorised spending',
          kind: CategoryKind.expense,
        ),
      );
    }
    if (!state.chart.hasCategory(UncategorisedIds.income)) {
      await state.store.createCategory(
        const Category(
          id: UncategorisedIds.income,
          name: 'Uncategorised income',
          kind: CategoryKind.income,
        ),
      );
    }
    state.refresh();
  }

  /// Previews an OFX or QIF statement, which needs no column mapping.
  ImportPreview previewStatement(
    Uint8List bytes,
    StatementFormat format, {
    required String accountId,
  }) {
    final CsvParseResult parsed = switch (format) {
      StatementFormat.ofx => parseOfxBytes(
        bytes,
        state.currency,
        accountId: accountId,
      ),
      StatementFormat.qif => parseQifBytes(
        bytes,
        state.currency,
        dateConvention: state.dateConvention,
      ),
      StatementFormat.csv => throw ArgumentError('CSV needs a column mapping'),
    };
    return previewImport(
      accountId: accountId,
      parsed: parsed,
      sourceHash: sourceHashOf(bytes),
      chart: state.chart,
      batches: batches,
      existingRecords: sourceRecords,
      journals: state.ledger.journals,
      receiptJournalIds: state.receipts.receiptJournalIds,
    );
  }

  Future<ImportOutcome> commitStatement(
    ImportPreview preview, {
    required String accountId,
    Map<int, RowDecision> decisions = const {},
    String? fileName,
  }) => _commit(
    preview,
    accountId: accountId,
    decisions: decisions,
    fileName: fileName,
  );

  Future<ImportOutcome> commit(
    ImportPreview preview,
    CsvMapping mapping, {
    Map<int, RowDecision> decisions = const {},
    String? fileName,
  }) => _commit(
    preview,
    accountId: mapping.accountId,
    mappingId: mapping.id,
    decisions: decisions,
    fileName: fileName,
  );

  Future<ImportOutcome> _commit(
    ImportPreview preview, {
    required String accountId,
    String? mappingId,
    Map<int, RowDecision> decisions = const {},
    String? fileName,
  }) async {
    await _ensureUncategorised();
    final result = commitImport(
      preview: preview,
      chart: state.chart,
      batchId: newId(),
      importedAt: DateTime.now().toUtc(),
      uncategorisedExpenseId: UncategorisedIds.expense,
      uncategorisedIncomeId: UncategorisedIds.income,
      decisions: decisions,
      chooseCategory: ruleCategoryChooser(state.rules, accountId),
      mappingId: mappingId,
      fileName: fileName,
    );
    if (result.alreadyCommitted) {
      return ImportOutcome(result.batch, 0, alreadyCommitted: true);
    }
    for (final draft in result.drafts) {
      await state.store.postTransaction(draft);
    }
    for (final record in result.sourceRecords) {
      await state.store.upsertEntity(
        ImportEntityTypes.sourceRecord,
        record.id,
        sourceRecordToJson(record),
      );
    }
    await state.store.upsertEntity(
      ImportEntityTypes.batch,
      result.batch.id,
      importBatchToJson(result.batch),
    );
    state.refresh();
    return ImportOutcome(
      result.batch,
      result.drafts.length,
      alreadyCommitted: false,
    );
  }
}
