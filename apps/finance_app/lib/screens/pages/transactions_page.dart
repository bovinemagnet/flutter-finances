import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../features/transactions/transaction_list.dart';
import '../editors.dart';

/// Review queue and full history (Journeys C and D).
class TransactionsPage extends StatelessWidget {
  const TransactionsPage({
    super.key,
    this.onlyJournalIds,
    this.receiptJournalIds = const {},
  });

  /// Restricts the list, for example after drilling into a report.
  final List<String>? onlyJournalIds;
  final Set<String> receiptJournalIds;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chart = state.chart;
    final reviewed = state.reviewedJournalIds;
    String categoryLabel(Journal j) {
      final categories = [
        for (final p in j.postings)
          if (chart.hasCategory(p.ledgerAccountId))
            chart.category(p.ledgerAccountId).name,
      ];
      if (categories.length > 1) return 'Split (${categories.length})';
      if (categories.isNotEmpty) return categories.single;
      return transactionTypeLabels[j.type]!;
    }

    final journals =
        state.ledger.journals
            .where(
              (j) =>
                  j.type != TransactionType.reversal &&
                  (onlyJournalIds == null || onlyJournalIds!.contains(j.id)),
            )
            .toList()
          ..sort((a, b) {
            final byDate = b.effectiveDate.compareTo(a.effectiveDate);
            return byDate != 0 ? byDate : b.enteredAt.compareTo(a.enteredAt);
          });
    final items = [
      for (final j in journals)
        TransactionListItem(
          journal: j,
          accountName: j.accountId != null && chart.hasAccount(j.accountId!)
              ? chart.account(j.accountId!).name
              : '',
          categoryLabel: categoryLabel(j),
          reviewed:
              reviewed.contains(j.id) ||
              j.type == TransactionType.openingBalance ||
              j.status == JournalStatus.reversed,
          hasReceipt: receiptJournalIds.contains(j.id),
          unsynced: state.isUnsynced('journal', j.id),
        ),
    ];
    Future<void> categorise(List<String> ids, String categoryId) async {
      final messenger = ScaffoldMessenger.of(context);
      final skipped = await state.categorise(ids, categoryId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            skipped == 0
                ? 'Categorised ${ids.length} entries'
                : 'Categorised ${ids.length - skipped}; $skipped split or uncategorised entries were left unchanged',
          ),
        ),
      );
    }

    final list = (bool onlyUnreviewed) => TransactionList(
      items: onlyUnreviewed ? items.where((i) => !i.reviewed).toList() : items,
      categories: chart.categories.toList(),
      onOpen: (j) => openTransactionEditor(context, journal: j),
      onMarkReviewed: state.markReviewed,
      onCategorise: categorise,
      emptyMessage: onlyUnreviewed
          ? 'Everything is reviewed'
          : 'No transactions yet',
    );
    if (onlyJournalIds != null) return list(false);
    final toReview = items.where((i) => !i.reviewed).length;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'To review ($toReview)'),
              const Tab(text: 'All'),
            ],
          ),
          Expanded(child: TabBarView(children: [list(true), list(false)])),
        ],
      ),
    );
  }
}
