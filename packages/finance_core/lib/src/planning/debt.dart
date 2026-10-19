import 'package:meta/meta.dart';

import '../ledger/accounts.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';

/// A loan's principal, interest and fees for a period (BUD 06).
@immutable
class LoanSummary {
  const LoanSummary({
    required this.accountId,
    required this.outstanding,
    required this.principalRepaid,
    required this.interest,
    required this.fees,
    required this.principalJournalIds,
    required this.interestJournalIds,
    required this.feeJournalIds,
  });

  final String accountId;

  /// Amount owed at the end of the period.
  final Money outstanding;

  /// Principal repaid by transfers from owned accounts; a cash commitment
  /// that reduces the liability, never an expense.
  final Money principalRepaid;

  /// Interest charged to the loan; an expense.
  final Money interest;

  /// Fees charged to the loan; an expense.
  final Money fees;
  final List<String> principalJournalIds;
  final List<String> interestJournalIds;
  final List<String> feeJournalIds;
}

/// Separates a loan's activity in [from]..[to] into principal, interest
/// and fees.
///
/// Principal repaid counts postings to the loan in posted journals that only
/// touch owned accounts (transfers and their reversals). Interest and fees
/// are postings to the given categories in journals charged to the loan.
LoanSummary summariseLoan(
  LedgerProjection ledger,
  String loanAccountId,
  LocalDate from,
  LocalDate to, {
  Set<String> interestCategoryIds = const {},
  Set<String> feeCategoryIds = const {},
}) {
  final chart = ledger.chart;
  if (chart.account(loanAccountId).type != AccountType.loan) {
    throw ArgumentError.value(loanAccountId, 'loanAccountId', 'not a loan');
  }
  final zero = Money.zero(chart.currency);
  var principal = zero;
  var interest = zero;
  var fees = zero;
  final principalIds = <String>[];
  final interestIds = <String>[];
  final feeIds = <String>[];
  for (final journal in ledger.journals) {
    if (!journal.status.inPostedLedger ||
        journal.effectiveDate < from ||
        journal.effectiveDate > to) {
      continue;
    }
    final loanAmount = journal.amountFor(loanAccountId);
    if (loanAmount == null) continue;
    if (journal.postings.every((p) => chart.hasAccount(p.ledgerAccountId))) {
      principal += loanAmount;
      principalIds.add(journal.id);
      continue;
    }
    for (final posting in journal.postings) {
      if (interestCategoryIds.contains(posting.ledgerAccountId)) {
        interest += posting.amount;
        if (!interestIds.contains(journal.id)) interestIds.add(journal.id);
      } else if (feeCategoryIds.contains(posting.ledgerAccountId)) {
        fees += posting.amount;
        if (!feeIds.contains(journal.id)) feeIds.add(journal.id);
      }
    }
  }
  return LoanSummary(
    accountId: loanAccountId,
    outstanding: ledger.displayBalance(loanAccountId, asOf: to),
    principalRepaid: principal,
    interest: interest,
    fees: fees,
    principalJournalIds: principalIds,
    interestJournalIds: interestIds,
    feeJournalIds: feeIds,
  );
}
