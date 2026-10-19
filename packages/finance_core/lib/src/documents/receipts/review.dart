import 'package:meta/meta.dart';

import '../../ids.dart';
import '../../ledger/accounts.dart';
import '../../ledger/journal.dart';
import '../../ledger/transaction_draft.dart';
import '../../money/money.dart';
import 'receipt.dart';
import 'receipt_link.dart';
import 'receipt_states.dart';

/// What the user chose on the review screen (REC 06).
sealed class ReviewDecision {
  const ReviewDecision();
}

/// Link the receipt to an existing entry. Nothing is posted (A07).
class AttachToTransaction extends ReviewDecision {
  const AttachToTransaction(this.journal, {this.allocated});

  final Journal journal;

  /// The confirmed allocation. When omitted, the receipt total is used, and
  /// only when it equals the journal amount; otherwise the user must
  /// confirm a partial allocation explicitly.
  final Money? allocated;
}

/// Prepare a new expense (or refund, for a refund receipt) from the
/// confirmed fields. The result is a [TransactionDraft]; posting it is a
/// separate, explicit step through the normal command path.
class CreateExpense extends ReviewDecision {
  const CreateExpense({
    required this.accountId,
    this.categoryId,
    this.splits = const [],
    this.paidInCash = false,
    this.accountConfirmed = false,
  });

  final String accountId;

  /// A single category for the whole total; ignored when [splits] is set.
  final String? categoryId;
  final List<Split> splits;

  /// The receipt shows a cash payment.
  final bool paidInCash;

  /// The user explicitly chose or confirmed [accountId] rather than
  /// accepting a suggestion. Required for cash accounts.
  final bool accountConfirmed;
}

/// Keep the document without any financial entry.
class KeepDocumentOnly extends ReviewDecision {
  const KeepDocumentOnly();
}

enum ReviewErrorCode {
  missingTotal('MISSING_TOTAL'),
  missingDate('MISSING_DATE'),
  currencyMismatch('CURRENCY_MISMATCH'),
  unknownAccount('UNKNOWN_ACCOUNT'),
  cashAccountUnconfirmed('CASH_ACCOUNT_UNCONFIRMED'),
  cashAccountRequired('CASH_ACCOUNT_REQUIRED'),
  allocationRequired('ALLOCATION_REQUIRED'),
  invalidLink('INVALID_LINK'),
  invalidDraft('INVALID_DRAFT');

  const ReviewErrorCode(this.code);
  final String code;
}

class ReviewException implements Exception {
  ReviewException(this.code, [this.detail]);
  final ReviewErrorCode code;
  final String? detail;

  @override
  String toString() =>
      'ReviewException(${code.code}${detail == null ? '' : ': $detail'})';
}

@immutable
class ReviewResult {
  const ReviewResult({required this.receipt, this.link, this.draft});

  /// The receipt marked reviewed, with the confirmed fields recorded.
  final Receipt receipt;

  /// A confirmed link (to the chosen entry, or to the new draft's id).
  final ReceiptTransactionLink? link;

  /// The proposed entry for [CreateExpense]; never a posted journal.
  final TransactionDraft? draft;
}

/// Completes review of [receipt] with the user's [confirmed] fields and
/// [decision] (REC 06). Throws [ReviewException] when the decision cannot
/// be honoured and [IllegalTransitionException] when the receipt cannot be
/// reviewed in its current state (for example while extracting).
ReviewResult reviewReceipt({
  required Receipt receipt,
  required ReceiptFields confirmed,
  required ReviewDecision decision,
  required Chart chart,
  required Iterable<ReceiptTransactionLink> existingLinks,
  required DateTime now,
  String? linkId,
}) {
  final reviewed = receipt.withExtractionEvent(ExtractionEvent.review);
  final fields = reviewed.confirmed.merge(confirmed);
  switch (decision) {
    case KeepDocumentOnly():
      return ReviewResult(
        receipt: reviewed.copyWith(
          confirmed: fields,
          outcome: ReviewOutcome.documentOnly,
        ),
      );
    case AttachToTransaction(:final journal, :final allocated):
      final journalAmount = journal.amount;
      final amount =
          allocated ??
          (fields.total != null && fields.total == journalAmount?.abs()
              ? fields.total
              : null);
      if (amount == null) {
        throw ReviewException(
          ReviewErrorCode.allocationRequired,
          'Confirm how much of the entry this receipt covers',
        );
      }
      final link = _link(
        linkId,
        receipt.id,
        journal,
        amount,
        fields.total,
        existingLinks,
        now,
      );
      return ReviewResult(
        receipt: reviewed.copyWith(
          confirmed: fields,
          outcome: ReviewOutcome.attachedToTransaction,
        ),
        link: link,
      );
    case CreateExpense():
      final draft = _expenseDraft(fields, decision, chart, reviewed);
      final journal = _validate(chart, draft);
      final link = _link(
        linkId,
        receipt.id,
        journal,
        draft.amount,
        fields.total,
        existingLinks,
        now,
      );
      return ReviewResult(
        receipt: reviewed.copyWith(
          confirmed: fields,
          outcome: ReviewOutcome.expenseCreated,
        ),
        link: link,
        draft: draft,
      );
  }
}

ReceiptTransactionLink _link(
  String? linkId,
  String receiptId,
  Journal journal,
  Money allocated,
  Money? receiptTotal,
  Iterable<ReceiptTransactionLink> existing,
  DateTime now,
) {
  try {
    return confirmLink(
      id: linkId ?? newId(),
      receiptId: receiptId,
      journal: journal,
      allocated: allocated,
      receiptTotal: receiptTotal,
      existing: existing,
      confirmedAt: now,
    );
  } on LinkException catch (error) {
    throw ReviewException(ReviewErrorCode.invalidLink, error.toString());
  }
}

TransactionDraft _expenseDraft(
  ReceiptFields fields,
  CreateExpense decision,
  Chart chart,
  Receipt receipt,
) {
  final total = fields.total;
  if (total == null) throw ReviewException(ReviewErrorCode.missingTotal);
  final date = fields.date;
  if (date == null) throw ReviewException(ReviewErrorCode.missingDate);
  if (total.currency != chart.currency) {
    throw ReviewException(
      ReviewErrorCode.currencyMismatch,
      'Enter the amount charged in ${chart.currency}',
    );
  }
  if (!chart.hasAccount(decision.accountId)) {
    throw ReviewException(ReviewErrorCode.unknownAccount, decision.accountId);
  }
  final isCashAccount =
      chart.account(decision.accountId).type == AccountType.cash;
  if (decision.paidInCash && !isCashAccount) {
    throw ReviewException(
      ReviewErrorCode.cashAccountRequired,
      'A cash purchase is paid from a cash account',
    );
  }
  if ((isCashAccount || decision.paidInCash) && !decision.accountConfirmed) {
    throw ReviewException(
      ReviewErrorCode.cashAccountUnconfirmed,
      'Confirm which cash account paid',
    );
  }
  final splits = decision.splits.isNotEmpty
      ? decision.splits
      : [if (decision.categoryId != null) Split(decision.categoryId!, total)];
  return TransactionDraft(
    id: newId(),
    type: fields.isRefund == true
        ? TransactionType.refund
        : TransactionType.expense,
    accountId: decision.accountId,
    amount: total.abs(),
    effectiveDate: date,
    splits: splits,
    payee: fields.merchant,
    notes: receipt.notes,
    tags: receipt.tags,
  );
}

/// Builds the draft once to surface ledger errors at review time; the
/// journal is discarded, so nothing is posted.
Journal _validate(Chart chart, TransactionDraft draft) {
  try {
    return JournalFactory(chart).build(draft);
  } on DraftException catch (error) {
    throw ReviewException(ReviewErrorCode.invalidDraft, error.toString());
  }
}
