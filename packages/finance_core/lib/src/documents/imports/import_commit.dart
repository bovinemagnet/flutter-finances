import 'package:meta/meta.dart';

import '../../ids.dart';
import '../../ledger/accounts.dart';
import '../../ledger/journal.dart';
import '../../ledger/transaction_draft.dart';
import 'csv_parse.dart';
import 'import_batch.dart';
import 'import_preview.dart';
import 'source_record.dart';

/// The user's choice for one preview row.
sealed class RowDecision {
  const RowDecision();
}

/// Create an expense (money out), income (money into an asset account) or
/// refund (money back onto a card or loan).
class CreateEntry extends RowDecision {
  const CreateEntry({this.categoryId});

  /// Overrides the chosen or default category.
  final String? categoryId;
}

/// Record the row as a transfer with another of the user's accounts.
class CreateTransfer extends RowDecision {
  const CreateTransfer(this.counterAccountId);
  final String counterAccountId;
}

/// Confirm the row as evidence for an existing entry (MATCH 03). Nothing
/// new is posted; the source record points at the entry.
class MatchExisting extends RowDecision {
  const MatchExisting(this.journalId);
  final String journalId;
}

/// Keep the row as evidence only.
class SkipRow extends RowDecision {
  const SkipRow();
}

/// Suggests a category for a new entry, for example from rules.
typedef CategoryChooser = String? Function(ImportRow row);

class ImportCommitException implements Exception {
  ImportCommitException(this.code, this.rows, [this.detail]);

  /// `UNRESOLVED_ROWS`, `INVALID_MATCH` or `INVALID_ENTRY`.
  final String code;
  final List<int> rows;
  final String? detail;

  @override
  String toString() =>
      'ImportCommitException($code, rows $rows${detail == null ? '' : ', $detail'})';
}

@immutable
class ImportCommit {
  ImportCommit({
    required this.batch,
    required List<SourceRecord> sourceRecords,
    required List<TransactionDraft> drafts,
    this.alreadyCommitted = false,
  }) : sourceRecords = List.unmodifiable(sourceRecords),
       drafts = List.unmodifiable(drafts);

  final ImportBatch batch;

  /// Evidence for every valid row, kept apart from the journals.
  final List<SourceRecord> sourceRecords;

  /// Entries to post through the normal command path.
  final List<TransactionDraft> drafts;

  /// The file was committed before; [batch] is that earlier batch (A12).
  final bool alreadyCommitted;
}

/// Commits a reviewed preview into drafts and provenance (IMP 01, IMP 02).
///
/// Rows default as follows: duplicates are recorded as duplicates, new
/// rows create entries, and any row that requires a decision must have
/// one in [decisions] (keyed by row number) or `UNRESOLVED_ROWS` is
/// thrown. A file that was already committed returns that batch with no
/// drafts. Every draft is checked against [chart] before returning, so a
/// failure leaves nothing half committed.
ImportCommit commitImport({
  required ImportPreview preview,
  required Chart chart,
  required String batchId,
  required DateTime importedAt,
  required String uncategorisedExpenseId,
  required String uncategorisedIncomeId,
  Map<int, RowDecision> decisions = const {},
  CategoryChooser? chooseCategory,
  String? mappingId,
  String? fileName,
}) {
  final already = preview.alreadyImportedBatch;
  if (already != null) {
    return ImportCommit(
      batch: already,
      sourceRecords: const [],
      drafts: const [],
      alreadyCommitted: true,
    );
  }
  final unresolved = [
    for (final row in preview.rows)
      if (row.requiresDecision && !decisions.containsKey(row.row.rowNumber))
        row.row.rowNumber,
  ];
  if (unresolved.isNotEmpty) {
    throw ImportCommitException('UNRESOLVED_ROWS', unresolved);
  }

  final factory = JournalFactory(chart);
  final liability = chart.account(preview.accountId).type.isLiability;
  final records = <SourceRecord>[];
  final drafts = <TransactionDraft>[];
  for (final previewRow in preview.rows) {
    final row = previewRow.row;
    final decision =
        decisions[row.rowNumber] ??
        (previewRow.status == PreviewRowStatus.duplicate
            ? null
            : const CreateEntry());
    SourceRecord record(SourceDecision outcome, String? journalId) =>
        SourceRecord(
          id: newId(),
          batchId: batchId,
          accountId: preview.accountId,
          rowNumber: row.rowNumber,
          fingerprint: previewRow.fingerprint,
          raw: row.raw,
          date: row.date,
          amount: row.amount,
          description: row.description,
          reference: row.reference,
          decision: outcome,
          journalId: journalId,
        );

    switch (decision) {
      case null:
        records.add(
          record(SourceDecision.duplicate, previewRow.duplicateOf?.journalId),
        );
      case SkipRow():
        records.add(record(SourceDecision.skipped, null));
      case MatchExisting(:final journalId):
        final allowed = {
          for (final p in previewRow.proposals) p.journal.id,
          ?previewRow.transferCounterpart?.id,
          ?previewRow.duplicateOf?.journalId,
        };
        if (!allowed.contains(journalId)) {
          throw ImportCommitException('INVALID_MATCH', [
            row.rowNumber,
          ], journalId);
        }
        records.add(record(SourceDecision.matchedExisting, journalId));
      case CreateTransfer(:final counterAccountId):
        final out = row.amount.isNegative;
        final draft = TransactionDraft(
          id: newId(),
          type: TransactionType.transfer,
          accountId: out ? preview.accountId : counterAccountId,
          counterAccountId: out ? counterAccountId : preview.accountId,
          amount: row.amount.abs(),
          effectiveDate: row.date,
          payee: row.description,
        );
        drafts.add(_checked(factory, draft, row));
        records.add(record(SourceDecision.created, draft.id));
      case CreateEntry(:final categoryId):
        final type = row.amount.isNegative
            ? TransactionType.expense
            : liability
            ? TransactionType.refund
            : TransactionType.income;
        final category =
            categoryId ??
            chooseCategory?.call(row) ??
            (type == TransactionType.income
                ? uncategorisedIncomeId
                : uncategorisedExpenseId);
        final draft = TransactionDraft(
          id: newId(),
          type: type,
          accountId: preview.accountId,
          amount: row.amount.abs(),
          effectiveDate: row.date,
          splits: [Split(category, row.amount.abs())],
          payee: row.description,
        );
        drafts.add(_checked(factory, draft, row));
        records.add(record(SourceDecision.created, draft.id));
    }
  }
  return ImportCommit(
    batch: ImportBatch(
      id: batchId,
      accountId: preview.accountId,
      sourceHash: preview.sourceHash,
      importedAt: importedAt.toUtc(),
      rowCount: preview.rows.length,
      errorCount: preview.errors.length,
      mappingId: mappingId,
      fileName: fileName,
    ),
    sourceRecords: records,
    drafts: drafts,
  );
}

TransactionDraft _checked(
  JournalFactory factory,
  TransactionDraft draft,
  ImportRow row,
) {
  try {
    factory.build(draft);
  } on DraftException catch (error) {
    throw ImportCommitException('INVALID_ENTRY', [
      row.rowNumber,
    ], error.toString());
  }
  return draft;
}
