import 'package:meta/meta.dart';

import '../../ledger/accounts.dart';
import '../../ledger/corrections.dart';
import '../../ledger/journal.dart';
import '../receipts/receipt_link.dart';
import 'import_batch.dart';
import 'source_record.dart';

enum RollbackIssueKind {
  /// The entry was corrected after import; its current version differs.
  editedAfterImport,

  /// A receipt is linked to the entry.
  linkedToReceipt,

  /// The entry falls within a completed reconciliation.
  reconciled,
}

/// An entry the rollback will not reverse without an explicit decision.
@immutable
class RollbackIssue {
  const RollbackIssue({
    required this.journalId,
    required this.currentJournalId,
    required this.kind,
    required this.message,
  });

  /// The journal the batch created.
  final String journalId;

  /// Its current version after any corrections.
  final String currentJournalId;
  final RollbackIssueKind kind;
  final String message;
}

/// The reversal plan for an import batch (IMP 02). Nothing is deleted:
/// posted entries are voided with linked reversals, and the source records
/// stay as evidence marked rolled back.
@immutable
class RollbackPlan {
  RollbackPlan({
    required this.batch,
    required List<CorrectionResult> corrections,
    required Set<String> pendingJournalIdsToRemove,
    required Set<String> linkIdsToRemove,
    required List<SourceRecord> sourceRecords,
    required List<RollbackIssue> issues,
  }) : corrections = List.unmodifiable(corrections),
       pendingJournalIdsToRemove = Set.unmodifiable(pendingJournalIdsToRemove),
       linkIdsToRemove = Set.unmodifiable(linkIdsToRemove),
       sourceRecords = List.unmodifiable(sourceRecords),
       issues = List.unmodifiable(issues);

  final ImportBatch batch;

  /// Voids (reversal, no replacement) of posted entries.
  final List<CorrectionResult> corrections;

  /// Pending or draft entries created by the batch; they never reached the
  /// posted ledger and can be removed.
  final Set<String> pendingJournalIdsToRemove;

  /// Receipt links to voided entries (only for entries in `include`).
  final Set<String> linkIdsToRemove;
  final List<SourceRecord> sourceRecords;

  /// Entries left untouched until the user decides.
  final List<RollbackIssue> issues;
}

/// Plans the rollback of [batch] (IMP 02).
///
/// Entries created by the batch are voided when untouched. Entries later
/// corrected, linked to a receipt or inside a reconciled period are
/// reported as [issues] instead, unless their original id is in
/// [include], in which case their current version is voided too and its
/// receipt links are listed for removal. Records that only matched an
/// existing entry lose that provenance; the entry itself is kept.
RollbackPlan planRollback({
  required ImportBatch batch,
  required Iterable<SourceRecord> sourceRecords,
  required Iterable<Journal> journals,
  required Iterable<ReceiptTransactionLink> links,
  required Chart chart,
  required DateTime now,
  Set<String> include = const {},
}) {
  final byId = {for (final j in journals) j.id: j};
  final replacedBy = {
    for (final j in journals)
      if (j.replaces != null) j.replaces!: j,
  };
  final corrections = <CorrectionResult>[];
  final pending = <String>{};
  final linkIds = <String>{};
  final issues = <RollbackIssue>[];
  final records = <SourceRecord>[];

  for (final record in sourceRecords) {
    if (record.batchId != batch.id) continue;
    records.add(record.copyWith(rolledBack: true));
    if (record.decision != SourceDecision.created) continue;
    final original = byId[record.journalId];
    if (original == null) continue;
    var current = original;
    while (current.status == JournalStatus.reversed &&
        replacedBy[current.id] != null) {
      current = replacedBy[current.id]!;
    }
    if (current.status == JournalStatus.reversed) continue; // already void
    if (current.status == JournalStatus.draft ||
        current.status == JournalStatus.pending) {
      pending.add(current.id);
      continue;
    }
    final currentLinks = links
        .where((l) => l.journalId == current.id)
        .map((l) => l.id)
        .toSet();
    final reconciledOn =
        current.accountId == null || !chart.hasAccount(current.accountId!)
        ? null
        : chart.account(current.accountId!).lastReconciledOn;
    final kinds = [
      if (current.id != original.id) RollbackIssueKind.editedAfterImport,
      if (currentLinks.isNotEmpty) RollbackIssueKind.linkedToReceipt,
      if (reconciledOn != null && current.effectiveDate <= reconciledOn)
        RollbackIssueKind.reconciled,
    ];
    if (kinds.isNotEmpty && !include.contains(original.id)) {
      for (final kind in kinds) {
        issues.add(
          RollbackIssue(
            journalId: original.id,
            currentJournalId: current.id,
            kind: kind,
            message: switch (kind) {
              RollbackIssueKind.editedAfterImport =>
                'Edited after import; choose whether to remove the edited '
                    'entry',
              RollbackIssueKind.linkedToReceipt =>
                'A receipt is attached; removing the entry keeps the receipt',
              RollbackIssueKind.reconciled =>
                'Inside a reconciled statement; removing it changes that '
                    'reconciliation',
            },
          ),
        );
      }
      continue;
    }
    corrections.add(correctJournal(current, null));
    linkIds.addAll(currentLinks);
  }
  return RollbackPlan(
    batch: batch.rolledBack(now),
    corrections: corrections,
    pendingJournalIdsToRemove: pending,
    linkIdsToRemove: linkIds,
    sourceRecords: records,
    issues: issues,
  );
}
