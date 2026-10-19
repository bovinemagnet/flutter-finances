import 'package:meta/meta.dart';

import '../../ledger/corrections.dart';
import '../../ledger/journal.dart';
import '../../money/money.dart';

/// A user-confirmed relationship between a receipt and a journal (REC 07).
///
/// A link is evidence, not money: it never posts anything, so attaching a
/// receipt cannot create a second expense (A07). [allocated] is the part
/// of the journal the receipt accounts for, confirmed by the user.
@immutable
class ReceiptTransactionLink {
  const ReceiptTransactionLink({
    required this.id,
    required this.receiptId,
    required this.journalId,
    required this.allocated,
    required this.confirmedAt,
  });

  final String id;
  final String receiptId;
  final String journalId;
  final Money allocated;

  /// When the user confirmed the link (UTC).
  final DateTime confirmedAt;

  ReceiptTransactionLink withJournal(String journalId) =>
      ReceiptTransactionLink(
        id: id,
        receiptId: receiptId,
        journalId: journalId,
        allocated: allocated,
        confirmedAt: confirmedAt,
      );
}

enum LinkError {
  nonPositiveAllocation('NON_POSITIVE_ALLOCATION'),
  currencyMismatch('CURRENCY_MISMATCH'),
  duplicateLink('DUPLICATE_LINK'),
  journalNotLinkable('JOURNAL_NOT_LINKABLE'),
  exceedsTransactionAmount('EXCEEDS_TRANSACTION_AMOUNT'),
  exceedsReceiptTotal('EXCEEDS_RECEIPT_TOTAL');

  const LinkError(this.code);
  final String code;
}

class LinkException implements Exception {
  LinkException(this.errors);
  final List<LinkError> errors;

  @override
  String toString() => 'LinkException(${errors.map((e) => e.code).join(', ')})';
}

Money? _sum(Iterable<Money> amounts) =>
    amounts.isEmpty ? null : amounts.reduce((a, b) => a + b);

/// Total allocated to [journalId] across [links], or null when unlinked.
Money? linkedAmountForJournal(
  String journalId,
  Iterable<ReceiptTransactionLink> links,
) => _sum(links.where((l) => l.journalId == journalId).map((l) => l.allocated));

/// Total allocated from [receiptId] across [links], or null when unlinked.
Money? linkedAmountForReceipt(
  String receiptId,
  Iterable<ReceiptTransactionLink> links,
) => _sum(links.where((l) => l.receiptId == receiptId).map((l) => l.allocated));

/// Checks a proposed link against existing ones (REC 07).
///
/// The allocation must be positive and in the journal's currency; the pair
/// must not already be linked; the journal must be a live entry (not a
/// draft, a reversed original or a reversal); and the allocations to the
/// journal and from the receipt must not exceed the journal amount or the
/// receipt total ([receiptTotal] is skipped when unknown).
List<LinkError> validateLink({
  required String receiptId,
  required Journal journal,
  required Money allocated,
  required Iterable<ReceiptTransactionLink> existing,
  Money? receiptTotal,
}) {
  final errors = <LinkError>[];
  if (!allocated.isPositive) errors.add(LinkError.nonPositiveAllocation);
  final journalAmount = journal.amount;
  if ((journalAmount != null && journalAmount.currency != allocated.currency) ||
      (receiptTotal != null && receiptTotal.currency != allocated.currency)) {
    return [...errors, LinkError.currencyMismatch];
  }
  if (existing.any(
    (l) => l.receiptId == receiptId && l.journalId == journal.id,
  )) {
    errors.add(LinkError.duplicateLink);
  }
  if (journal.status == JournalStatus.draft ||
      journal.status == JournalStatus.reversed ||
      journal.type == TransactionType.reversal ||
      journalAmount == null) {
    errors.add(LinkError.journalNotLinkable);
  }
  if (errors.isNotEmpty) return errors;
  final toJournal = linkedAmountForJournal(journal.id, existing);
  if ((toJournal == null ? allocated : toJournal + allocated) >
      journalAmount!.abs()) {
    errors.add(LinkError.exceedsTransactionAmount);
  }
  if (receiptTotal != null) {
    final fromReceipt = linkedAmountForReceipt(receiptId, existing);
    if ((fromReceipt == null ? allocated : fromReceipt + allocated) >
        receiptTotal.abs()) {
      errors.add(LinkError.exceedsReceiptTotal);
    }
  }
  return errors;
}

/// Creates a link after the user confirmed it, or throws [LinkException].
ReceiptTransactionLink confirmLink({
  required String id,
  required String receiptId,
  required Journal journal,
  required Money allocated,
  required Iterable<ReceiptTransactionLink> existing,
  required DateTime confirmedAt,
  Money? receiptTotal,
}) {
  final errors = validateLink(
    receiptId: receiptId,
    journal: journal,
    allocated: allocated,
    existing: existing,
    receiptTotal: receiptTotal,
  );
  if (errors.isNotEmpty) throw LinkException(errors);
  return ReceiptTransactionLink(
    id: id,
    receiptId: receiptId,
    journalId: journal.id,
    allocated: allocated,
    confirmedAt: confirmedAt.toUtc(),
  );
}

/// Removes one link. The receipt, its document and the journal are kept.
List<ReceiptTransactionLink> unlink(
  Iterable<ReceiptTransactionLink> links,
  String linkId,
) {
  final remaining = links.where((l) => l.id != linkId).toList();
  if (remaining.length == links.length) {
    throw ArgumentError.value(linkId, 'linkId', 'no such link');
  }
  return remaining;
}

/// Moves links from a corrected journal to its replacement, so evidence
/// follows the entry. Links of a voided journal (no replacement) are
/// dropped; the receipts themselves are untouched.
List<ReceiptTransactionLink> relinkAfterCorrection(
  Iterable<ReceiptTransactionLink> links,
  CorrectionResult correction,
) {
  final originalId = correction.original.id;
  final replacement = correction.replacement;
  return [
    for (final link in links)
      if (link.journalId != originalId)
        link
      else if (replacement != null)
        link.withJournal(replacement.id),
  ];
}
