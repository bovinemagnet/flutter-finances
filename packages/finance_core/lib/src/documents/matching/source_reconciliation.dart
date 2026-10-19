import 'package:meta/meta.dart';

import '../../ledger/journal.dart';
import '../imports/csv_parse.dart';
import '../imports/source_record.dart';
import '../text/normalise.dart';
import 'match_reason.dart';

/// A proposal that an imported row is evidence for an existing entry
/// rather than a new purchase (MATCH 03, A08).
@immutable
class SourceMatchProposal {
  SourceMatchProposal({
    required this.journal,
    required this.receiptCreated,
    required List<MatchReason> reasons,
  }) : reasons = List.unmodifiable(reasons);

  final Journal journal;

  /// The entry was created from a receipt.
  final bool receiptCreated;
  final List<MatchReason> reasons;
}

/// Existing entries on [accountId] with exactly the row's amount (as the
/// account sees it) within [dateWindowDays]. Receipt-created entries come
/// first, then the nearest dates. Entries already matched to another
/// source record, reversed originals, reversals and drafts are skipped.
/// A changed amount is never proposed.
List<SourceMatchProposal> proposeSourceMatches(
  ImportRow row, {
  required String accountId,
  required Iterable<Journal> journals,
  Set<String> receiptJournalIds = const {},
  Set<String> alreadyMatchedJournalIds = const {},
  int dateWindowDays = 3,
}) {
  final proposals = <(SourceMatchProposal, int)>[];
  for (final journal in journals) {
    if (journal.status == JournalStatus.draft ||
        journal.status == JournalStatus.reversed ||
        journal.type == TransactionType.reversal ||
        alreadyMatchedJournalIds.contains(journal.id)) {
      continue;
    }
    final delta = journal.amountFor(accountId);
    if (delta == null || delta != row.amount) continue;
    final days = row.date.daysUntil(journal.effectiveDate).abs();
    if (days > dateWindowDays) continue;
    final receipt = receiptJournalIds.contains(journal.id);
    proposals.add((
      SourceMatchProposal(
        journal: journal,
        receiptCreated: receipt,
        reasons: [
          MatchReason(
            MatchReasonCode.sameAmount,
            'Same amount: ${row.amount.abs().toDecimalString()} '
            '${row.amount.currency}',
          ),
          dateReason(row.date, journal.effectiveDate, 'statement row'),
          if (receipt)
            const MatchReason(
              MatchReasonCode.receiptEntry,
              'Entered from a receipt; confirming adds the bank record as '
              'evidence instead of a second purchase',
            ),
          if (journal.payee != null &&
              merchantSimilarity(journal.payee!, row.description) >= 0.5)
            MatchReason(
              MatchReasonCode.merchantSimilar,
              'Merchant similar to "${journal.payee}"',
            ),
        ],
      ),
      days,
    ));
  }
  proposals.sort((a, b) {
    if (a.$1.receiptCreated != b.$1.receiptCreated) {
      return a.$1.receiptCreated ? -1 : 1;
    }
    return a.$2.compareTo(b.$2);
  });
  return [for (final p in proposals) p.$1];
}

enum PendingLinkBasis { provider, heuristic }

/// A proposal that a posted record supersedes a pending one.
@immutable
class PendingPostedMatch {
  PendingPostedMatch({
    required this.posted,
    required this.pending,
    required this.basis,
    required this.amountChanged,
    required this.dateChanged,
    List<SourceRecord> alternatives = const [],
  }) : alternatives = List.unmodifiable(alternatives);

  final SourceRecord posted;
  final SourceRecord pending;
  final PendingLinkBasis basis;
  final bool amountChanged;
  final bool dateChanged;

  /// Other pending records the heuristic found equally or less plausible.
  final List<SourceRecord> alternatives;

  /// A provider relationship is authoritative. A heuristic proposal needs
  /// review when the amount or date changed or other candidates exist, so
  /// unrelated entries are never merged silently.
  bool get requiresReview =>
      basis == PendingLinkBasis.heuristic &&
      (amountChanged || dateChanged || alternatives.isNotEmpty);
}

/// Finds the pending record that [posted] replaces (MATCH 03).
///
/// A provider-supplied [SourceRecord.pendingReference] equal to a pending
/// record's reference wins. Otherwise the heuristic considers pending
/// records on the same account with a similar description (merchant
/// similarity at least 0.8), a posting date from 0 to [dateWindowDays]
/// days after the pending date, the same direction and an amount within
/// [amountTolerancePercent] percent (tips, final fuel amounts). Exact
/// amounts rank first, then the nearest date.
PendingPostedMatch? matchPendingToPosted(
  SourceRecord posted,
  Iterable<SourceRecord> pendingRecords, {
  int dateWindowDays = 7,
  int amountTolerancePercent = 20,
}) {
  final pending = pendingRecords
      .where(
        (r) =>
            r.status == SourceStatus.pending &&
            r.accountId == posted.accountId &&
            r.id != posted.id &&
            !r.rolledBack,
      )
      .toList();
  PendingPostedMatch build(
    SourceRecord match,
    PendingLinkBasis basis, [
    List<SourceRecord> alternatives = const [],
  ]) => PendingPostedMatch(
    posted: posted,
    pending: match,
    basis: basis,
    amountChanged: match.amount != posted.amount,
    dateChanged: match.date != posted.date,
    alternatives: alternatives,
  );

  final link = posted.pendingReference;
  if (link != null) {
    for (final record in pending) {
      if (record.reference == link) {
        return build(record, PendingLinkBasis.provider);
      }
    }
  }
  final candidates = pending.where((r) {
    final days = r.date.daysUntil(posted.date);
    if (days < 0 || days > dateWindowDays) return false;
    if (r.amount.currency != posted.amount.currency ||
        r.amount.isNegative != posted.amount.isNegative) {
      return false;
    }
    final difference = (posted.amount.minor - r.amount.minor).abs();
    if (difference * 100 > r.amount.minor.abs() * amountTolerancePercent) {
      return false;
    }
    return merchantSimilarity(r.description, posted.description) >= 0.8;
  }).toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final exactA = a.amount == posted.amount;
    final exactB = b.amount == posted.amount;
    if (exactA != exactB) return exactA ? -1 : 1;
    final byDays = a.date
        .daysUntil(posted.date)
        .compareTo(b.date.daysUntil(posted.date));
    return byDays != 0 ? byDays : a.id.compareTo(b.id);
  });
  return build(
    candidates.first,
    PendingLinkBasis.heuristic,
    candidates.sublist(1),
  );
}
