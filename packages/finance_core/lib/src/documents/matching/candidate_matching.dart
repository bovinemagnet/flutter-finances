import 'package:meta/meta.dart';

import '../../ids.dart';
import '../../ledger/journal.dart';
import '../../money/money.dart';
import '../receipts/receipt.dart';
import '../receipts/receipt_link.dart';
import '../text/normalise.dart';
import 'match_reason.dart';

@immutable
class MatchSettings {
  const MatchSettings({
    this.dateWindowDays = 3,
    this.minimumMerchantSimilarity = 0.5,
  });

  /// Entries further than this from the receipt date are not candidates.
  final int dateWindowDays;

  /// Entries with a different amount are shown only when the merchant is
  /// at least this similar (see [merchantSimilarity]).
  final double minimumMerchantSimilarity;
}

/// An entry that may be the purchase on a receipt.
@immutable
class MatchCandidate {
  MatchCandidate({
    required this.journal,
    required this.linkable,
    required this.merchantSimilarity,
    required this.accountMatches,
    required List<MatchReason> reasons,
    this.dateDistance,
  }) : reasons = List.unmodifiable(reasons);

  final Journal journal;

  /// Same currency, exact amount, and not already fully linked. Even then
  /// the user must confirm (P0 never links automatically).
  final bool linkable;
  final double merchantSimilarity;
  final bool accountMatches;

  /// Absolute days between receipt and entry, when the receipt has a date.
  final int? dateDistance;
  final List<MatchReason> reasons;

  bool reasonIs(MatchReasonCode code) => reasons.any((r) => r.code == code);
}

/// Ranks entries that could match a receipt (MATCH 01).
///
/// Candidates are posted or pending entries (not drafts, reversed
/// originals or reversals) of the matching direction (refund entries for
/// refund receipts, others otherwise) within the date window. An entry is
/// listed when its amount is exactly the receipt total or its payee is
/// similar enough. Order: linkable (same currency and exact amount) first,
/// then merchant similarity, then the account hint, then date proximity.
List<MatchCandidate> rankMatchCandidates(
  ReceiptFields fields,
  Iterable<Journal> journals, {
  String? accountHint,
  Iterable<ReceiptTransactionLink> existingLinks = const [],
  MatchSettings settings = const MatchSettings(),
}) {
  final total = fields.total?.abs();
  final refund = fields.isRefund ?? false;
  final candidates = <MatchCandidate>[];
  for (final journal in journals) {
    final amount = journal.amount?.abs();
    if (amount == null ||
        !(journal.status == JournalStatus.posted ||
            journal.status == JournalStatus.pending) ||
        journal.type == TransactionType.reversal ||
        (journal.type == TransactionType.refund) != refund) {
      continue;
    }
    int? distance;
    if (fields.date != null) {
      distance = fields.date!.daysUntil(journal.effectiveDate).abs();
      if (distance > settings.dateWindowDays) continue;
    }
    final similarity = fields.merchant == null || journal.payee == null
        ? 0.0
        : merchantSimilarity(fields.merchant!, journal.payee!);
    final sameCurrency = total != null && total.currency == amount.currency;
    final exact = sameCurrency && total.minor == amount.minor;
    if (!exact && similarity < settings.minimumMerchantSimilarity) continue;

    final reasons = <MatchReason>[];
    var linkable = exact;
    if (total == null) {
      linkable = false;
    } else if (!sameCurrency) {
      reasons.add(
        MatchReason(
          MatchReasonCode.currencyMismatch,
          'Different currency: receipt ${total.currency}, entry '
          '${amount.currency}',
        ),
      );
    } else if (exact) {
      reasons.add(
        MatchReason(
          MatchReasonCode.sameAmount,
          'Same amount: ${amount.toDecimalString()} ${amount.currency}',
        ),
      );
      final linked = linkedAmountForJournal(journal.id, existingLinks);
      if (linked != null && linked >= amount) {
        linkable = false;
        reasons.add(
          const MatchReason(
            MatchReasonCode.alreadyLinked,
            'Already covered by another receipt',
          ),
        );
      }
    } else {
      reasons.add(
        MatchReason(
          MatchReasonCode.amountMismatch,
          'Amount differs: receipt ${total.toDecimalString()}, entry '
          '${amount.toDecimalString()}',
        ),
      );
    }
    if (similarity >= 1.0) {
      reasons.add(
        MatchReason(
          MatchReasonCode.merchantMatches,
          'Merchant matches "${journal.payee}"',
        ),
      );
    } else if (similarity >= settings.minimumMerchantSimilarity) {
      reasons.add(
        MatchReason(
          MatchReasonCode.merchantSimilar,
          'Merchant similar to "${journal.payee}"',
        ),
      );
    }
    final accountMatches =
        accountHint != null && journal.accountId == accountHint;
    if (accountMatches) {
      reasons.add(
        const MatchReason(
          MatchReasonCode.accountHint,
          'Paid from the suggested account',
        ),
      );
    }
    if (fields.date != null) {
      reasons.add(dateReason(fields.date!, journal.effectiveDate, 'receipt'));
    }
    candidates.add(
      MatchCandidate(
        journal: journal,
        linkable: linkable,
        merchantSimilarity: similarity,
        accountMatches: accountMatches,
        dateDistance: distance,
        reasons: reasons,
      ),
    );
  }
  candidates.sort((a, b) {
    if (a.linkable != b.linkable) return a.linkable ? -1 : 1;
    final bySimilarity = b.merchantSimilarity.compareTo(a.merchantSimilarity);
    if (bySimilarity != 0) return bySimilarity;
    if (a.accountMatches != b.accountMatches) return a.accountMatches ? -1 : 1;
    final byDate = (a.dateDistance ?? 0).compareTo(b.dateDistance ?? 0);
    if (byDate != 0) return byDate;
    return a.journal.id.compareTo(b.journal.id);
  });
  return candidates;
}

/// Turns a candidate the user explicitly confirmed into a link. Throws
/// [LinkException] for an amount or currency mismatch or an invalid
/// allocation.
ReceiptTransactionLink confirmMatch(
  MatchCandidate candidate, {
  required String receiptId,
  required Money? receiptTotal,
  required Iterable<ReceiptTransactionLink> existingLinks,
  required DateTime confirmedAt,
  String? linkId,
}) {
  if (candidate.reasonIs(MatchReasonCode.currencyMismatch)) {
    throw LinkException([LinkError.currencyMismatch]);
  }
  if (candidate.reasonIs(MatchReasonCode.amountMismatch) ||
      receiptTotal == null) {
    throw LinkException([LinkError.amountMismatch]);
  }
  return confirmLink(
    id: linkId ?? newId(),
    receiptId: receiptId,
    journal: candidate.journal,
    allocated: receiptTotal.abs(),
    receiptTotal: receiptTotal.abs(),
    existing: existingLinks,
    confirmedAt: confirmedAt,
  );
}
