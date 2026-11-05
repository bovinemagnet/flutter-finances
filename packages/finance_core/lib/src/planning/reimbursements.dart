import 'package:meta/meta.dart';

import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';

/// A payment made for someone else that has not been fully repaid.
@immutable
class OwedItem {
  OwedItem({
    required this.journal,
    required this.repaid,
    required this.outstanding,
    required List<String> repaymentIds,
  }) : repaymentIds = List.unmodifiable(repaymentIds);

  final Journal journal;
  final Money repaid;
  final Money outstanding;

  /// The repayments linked to this entry, in date order.
  final List<String> repaymentIds;
}

/// What other people owe the user.
@immutable
class OwedToMe {
  OwedToMe({
    required List<OwedItem> items,
    required this.total,
    required this.unmatched,
  }) : items = List.unmodifiable(items);

  /// Entries with money still to come, oldest first.
  final List<OwedItem> items;

  /// The ledger's own figure, never added up separately, so it cannot drift.
  final Money total;

  /// Repayments beyond what [items] account for: not linked to an entry, or
  /// more than the entry was for. The items less this always equal [total].
  final Money unmatched;
}

/// What is owed, from the reimbursement receivable (FIN 06). A repayment links
/// to its entry through [Journal.refundOf], and still counts when that entry
/// has since been corrected.
OwedToMe owedToMe(LedgerProjection ledger) {
  final currency = ledger.chart.currency;
  final zero = Money.zero(currency);
  final replacedBy = {for (final j in ledger.journals) ?j.replaces: j.id};
  String current(String id) {
    var at = id;
    final seen = {at};
    for (
      var next = replacedBy[at];
      next != null && seen.add(next);
      next = replacedBy[at]
    ) {
      at = next;
    }
    return at;
  }

  bool settled(Journal j) => j.status == JournalStatus.posted;
  final debts = [
    for (final j in ledger.journals)
      if (j.type == TransactionType.reimbursableExpense && settled(j)) j,
  ]..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
  final repayments = <String, List<Journal>>{};
  for (final j in ledger.journals) {
    if (j.type != TransactionType.reimbursement || !settled(j)) continue;
    if (j.refundOf case final debt?) {
      (repayments[current(debt)] ??= []).add(j);
    }
  }

  final items = <OwedItem>[];
  var listed = zero;
  for (final debt in debts) {
    final linked = (repayments[debt.id] ?? const <Journal>[]).toList()
      ..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
    final repaid = linked.fold(zero, (sum, j) => sum + (j.amount ?? zero));
    final amount = debt.amount ?? zero;
    final outstanding = amount - repaid;
    if (!outstanding.isPositive) continue;
    listed += outstanding;
    items.add(
      OwedItem(
        journal: debt,
        repaid: repaid,
        outstanding: outstanding,
        repaymentIds: [for (final j in linked) j.id],
      ),
    );
  }
  final total = ledger.ledgerBalance(SystemAccounts.reimbursementReceivable);
  return OwedToMe(items: items, total: total, unmatched: listed - total);
}
