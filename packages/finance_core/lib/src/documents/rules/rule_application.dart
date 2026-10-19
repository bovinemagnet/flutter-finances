import 'package:meta/meta.dart';

import '../../ids.dart';
import '../../ledger/accounts.dart';
import '../../ledger/corrections.dart';
import '../../ledger/journal.dart';
import 'categorisation_rule.dart';

/// One proposed recategorisation.
@immutable
class RuleChange {
  const RuleChange({
    required this.journalId,
    required this.fromCategoryId,
    required this.toCategoryId,
    required this.ruleId,
  });

  final String journalId;
  final String fromCategoryId;
  final String toCategoryId;
  final String ruleId;
}

enum RuleSkipReason {
  /// The user chose the category explicitly; rules never override that.
  userCategorised,

  /// The entry is split across categories; rules do not rewrite splits.
  splitEntry,

  /// The rule's category is of the other kind (income versus expense).
  incompatibleCategory,
}

@immutable
class RuleSkip {
  const RuleSkip(this.journalId, this.reason, this.ruleId);
  final String journalId;
  final RuleSkipReason reason;
  final String ruleId;
}

/// What bulk application would change, for the user to review (AUTO 01).
@immutable
class RuleApplicationPreview {
  RuleApplicationPreview(List<RuleChange> changes, List<RuleSkip> skipped)
    : changes = List.unmodifiable(changes),
      skipped = List.unmodifiable(skipped);

  final List<RuleChange> changes;

  /// Entries a rule matched but that are left alone, with the reason.
  final List<RuleSkip> skipped;
}

bool _eligible(Journal journal) =>
    journal.status != JournalStatus.reversed &&
    journal.type != TransactionType.reversal &&
    journal.type != TransactionType.transfer;

List<String> _categories(Journal journal, Chart chart) => {
  for (final p in journal.postings)
    if (chart.hasCategory(p.ledgerAccountId)) p.ledgerAccountId,
}.toList();

/// Lists the entries [rules] would recategorise. [descriptions] supplies
/// statement descriptions by journal id (for imported entries).
RuleApplicationPreview previewRuleApplication({
  required Iterable<CategorisationRule> rules,
  required Iterable<Journal> journals,
  required Chart chart,
  Map<String, CategorySource> categorySources = const {},
  Map<String, String> descriptions = const {},
}) {
  final changes = <RuleChange>[];
  final skipped = <RuleSkip>[];
  for (final journal in journals) {
    if (!_eligible(journal)) continue;
    final categories = _categories(journal, chart);
    if (categories.isEmpty) continue;
    final source = categorySources[journal.id] ?? CategorySource.none;
    final subject = RuleSubject(
      merchant: journal.payee,
      description: descriptions[journal.id] ?? journal.notes,
      accountId: journal.accountId,
      amount: journal.amount,
      tags: journal.tags,
      currentCategoryId: categories.first,
      categorySource: source,
    );
    final rule = firstMatchingRule(subject, rules);
    if (rule == null) continue;
    if (source == CategorySource.user) {
      skipped.add(
        RuleSkip(journal.id, RuleSkipReason.userCategorised, rule.id),
      );
      continue;
    }
    if (categories.length > 1) {
      skipped.add(RuleSkip(journal.id, RuleSkipReason.splitEntry, rule.id));
      continue;
    }
    if (!chart.hasCategory(rule.categoryId) ||
        chart.category(rule.categoryId).kind !=
            chart.category(categories.single).kind) {
      skipped.add(
        RuleSkip(journal.id, RuleSkipReason.incompatibleCategory, rule.id),
      );
      continue;
    }
    if (rule.categoryId == categories.single) continue;
    changes.add(
      RuleChange(
        journalId: journal.id,
        fromCategoryId: categories.single,
        toCategoryId: rule.categoryId,
        ruleId: rule.id,
      ),
    );
  }
  return RuleApplicationPreview(changes, skipped);
}

/// What is needed to reverse one applied change.
@immutable
class RuleUndoEntry {
  const RuleUndoEntry({
    required this.originalJournalId,
    required this.newJournalId,
    required this.previousCategoryId,
    required this.newCategoryId,
    required this.previousSource,
    required this.ruleId,
    required this.inPlace,
  });

  final String originalJournalId;

  /// The replacement journal, or the same id for a pending or draft entry
  /// replaced in place.
  final String newJournalId;
  final String previousCategoryId;
  final String newCategoryId;
  final CategorySource previousSource;
  final String ruleId;
  final bool inPlace;
}

@immutable
class RuleUndoRecord {
  RuleUndoRecord({
    required this.id,
    required this.appliedAt,
    required List<RuleUndoEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final String id;
  final DateTime appliedAt;
  final List<RuleUndoEntry> entries;
}

@immutable
class RuleApplicationResult {
  RuleApplicationResult({
    required List<CorrectionResult> corrections,
    required List<Journal> replacements,
    required Map<String, CategorySource> categorySources,
    required this.undo,
  }) : corrections = List.unmodifiable(corrections),
       replacements = List.unmodifiable(replacements),
       categorySources = Map.unmodifiable(categorySources);

  /// Posted entries: a reversal plus a recategorised replacement each.
  final List<CorrectionResult> corrections;

  /// Pending and draft entries replaced in place (same id).
  final List<Journal> replacements;

  /// New category sources by journal id.
  final Map<String, CategorySource> categorySources;
  final RuleUndoRecord undo;
}

Journal _recategorised(
  Journal journal,
  String from,
  String to, {
  required String id,
  required DateTime enteredAt,
}) => Journal(
  id: id,
  type: journal.type,
  status: journal.status,
  effectiveDate: journal.effectiveDate,
  enteredAt: enteredAt.toUtc(),
  postings: [
    for (final p in journal.postings)
      p.ledgerAccountId == from ? Posting(to, p.amount) : p,
  ],
  accountId: journal.accountId,
  counterAccountId: journal.counterAccountId,
  amount: journal.amount,
  payee: journal.payee,
  notes: journal.notes,
  tags: journal.tags,
  refundOf: journal.refundOf,
);

/// Applies a reviewed preview (AUTO 01).
///
/// A posted entry is never mutated: it is corrected with a reversal and a
/// replacement that only moves the category posting, so account balances,
/// journal balance and reconciled totals are unchanged (carry cleared ids
/// with [carryClearedJournals]; move receipt links with
/// `relinkAfterCorrection`). Pending and draft entries are replaced in
/// place. The result includes an undo record.
RuleApplicationResult applyRuleChanges(
  RuleApplicationPreview preview,
  Iterable<Journal> journals, {
  required Chart chart,
  required DateTime now,
  Map<String, CategorySource> categorySources = const {},
  String? undoId,
}) {
  final byId = {for (final j in journals) j.id: j};
  final corrections = <CorrectionResult>[];
  final replacements = <Journal>[];
  final sources = <String, CategorySource>{};
  final entries = <RuleUndoEntry>[];
  for (final change in preview.changes) {
    final journal = byId[change.journalId];
    if (journal == null) continue;
    final inPlace = !journal.status.inPostedLedger;
    final updated = _recategorised(
      journal,
      change.fromCategoryId,
      change.toCategoryId,
      id: inPlace ? journal.id : newId(),
      enteredAt: now,
    );
    if (inPlace) {
      replacements.add(updated);
    } else {
      corrections.add(correctJournal(journal, updated));
    }
    sources[updated.id] = CategorySource.rule;
    entries.add(
      RuleUndoEntry(
        originalJournalId: journal.id,
        newJournalId: updated.id,
        previousCategoryId: change.fromCategoryId,
        newCategoryId: change.toCategoryId,
        previousSource: categorySources[journal.id] ?? CategorySource.none,
        ruleId: change.ruleId,
        inPlace: inPlace,
      ),
    );
  }
  return RuleApplicationResult(
    corrections: corrections,
    replacements: replacements,
    categorySources: sources,
    undo: RuleUndoRecord(
      id: undoId ?? newId(),
      appliedAt: now.toUtc(),
      entries: entries,
    ),
  );
}

@immutable
class RuleUndoResult {
  RuleUndoResult({
    required List<CorrectionResult> corrections,
    required List<Journal> replacements,
    required Map<String, CategorySource> categorySources,
    required List<String> conflicts,
  }) : corrections = List.unmodifiable(corrections),
       replacements = List.unmodifiable(replacements),
       categorySources = Map.unmodifiable(categorySources),
       conflicts = List.unmodifiable(conflicts);

  final List<CorrectionResult> corrections;
  final List<Journal> replacements;
  final Map<String, CategorySource> categorySources;

  /// Journal ids changed since the rules ran; they are left for the user.
  final List<String> conflicts;
}

/// Reverses an application recorded in [undo], again through corrections
/// for posted entries. Entries edited since are reported as conflicts.
RuleUndoResult undoRuleApplication(
  RuleUndoRecord undo,
  Iterable<Journal> journals, {
  required Chart chart,
  required DateTime now,
}) {
  final byId = {for (final j in journals) j.id: j};
  final corrections = <CorrectionResult>[];
  final replacements = <Journal>[];
  final sources = <String, CategorySource>{};
  final conflicts = <String>[];
  for (final entry in undo.entries) {
    final current = byId[entry.newJournalId];
    if (current == null ||
        current.status == JournalStatus.reversed ||
        !_categories(current, chart).contains(entry.newCategoryId)) {
      conflicts.add(entry.newJournalId);
      continue;
    }
    final inPlace = !current.status.inPostedLedger;
    final restored = _recategorised(
      current,
      entry.newCategoryId,
      entry.previousCategoryId,
      id: inPlace ? current.id : newId(),
      enteredAt: now,
    );
    if (inPlace) {
      replacements.add(restored);
    } else {
      corrections.add(correctJournal(current, restored));
    }
    sources[restored.id] = entry.previousSource;
  }
  return RuleUndoResult(
    corrections: corrections,
    replacements: replacements,
    categorySources: sources,
    conflicts: conflicts,
  );
}

/// Carries reconciliation state through corrections: when an original was
/// cleared, its reversal and replacement are cleared too, so the cleared
/// balance of a completed reconciliation is unchanged.
Set<String> carryClearedJournals(
  Set<String> cleared,
  Iterable<CorrectionResult> corrections,
) => {
  ...cleared,
  for (final c in corrections)
    if (cleared.contains(c.original.id)) ...[c.reversal.id, ?c.replacement?.id],
};
