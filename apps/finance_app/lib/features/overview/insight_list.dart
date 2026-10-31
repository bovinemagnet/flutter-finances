import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

const insightTitles = {
  InsightRule.overBudget: 'Over budget',
  InsightRule.lowCash: 'Low cash ahead',
  InsightRule.unreviewed: 'Transactions to review',
  InsightRule.missingReceipt: 'Missing receipts',
  InsightRule.possibleDuplicate: 'Possible duplicate',
  InsightRule.possibleSubscription: 'Possible subscription',
  InsightRule.unusualTransaction: 'Unusual purchase',
  InsightRule.spendingSpike: 'Spending spike',
};

/// Explainable insights (REP 03): each shows its trigger and period, opens
/// its underlying entries, and can be dismissed, snoozed or switched off.
/// Insights never change money or budgets.
///
/// With a [limit], only the first insights are shown, followed by a "Show
/// all" action calling [onShowAll], so a long list never slows the page
/// holding it (NFR 02).
class InsightList extends StatelessWidget {
  const InsightList({
    super.key,
    required this.insights,
    required this.onOpen,
    required this.onDismiss,
    required this.onSnooze,
    required this.onDisableRule,
    this.onAddAsBill,
    this.limit,
    this.onShowAll,
  });

  final List<Insight> insights;
  final ValueChanged<Insight> onOpen;
  final ValueChanged<Insight> onDismiss;
  final ValueChanged<Insight> onSnooze;
  final ValueChanged<InsightRule> onDisableRule;

  /// Turns a possible subscription into a confirmed bill.
  final ValueChanged<Insight>? onAddAsBill;

  final int? limit;
  final VoidCallback? onShowAll;

  InsightCard card(Insight insight) => InsightCard(
    insight: insight,
    onOpen: onOpen,
    onDismiss: onDismiss,
    onSnooze: onSnooze,
    onDisableRule: onDisableRule,
    onAddAsBill: onAddAsBill,
  );

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.check_circle_outline),
        title: Text('Nothing needs attention'),
      );
    }
    final shown = limit == null || insights.length <= limit!
        ? insights
        : insights.take(limit!);
    return Column(
      children: [
        for (final insight in shown) card(insight),
        if (shown.length < insights.length)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onShowAll,
              child: Text('Show all ${insights.length}'),
            ),
          ),
      ],
    );
  }
}

/// One insight with its explanation and actions.
class InsightCard extends StatelessWidget {
  const InsightCard({
    super.key,
    required this.insight,
    required this.onOpen,
    required this.onDismiss,
    required this.onSnooze,
    required this.onDisableRule,
    this.onAddAsBill,
  });

  final Insight insight;
  final ValueChanged<Insight> onOpen;
  final ValueChanged<Insight> onDismiss;
  final ValueChanged<Insight> onSnooze;
  final ValueChanged<InsightRule> onDisableRule;
  final ValueChanged<Insight>? onAddAsBill;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            insightTitles[insight.rule]!,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(insight.trigger),
          Text(
            '${insight.period.label} · ${insight.entryIds.length} '
            '${insight.entryIds.length == 1 ? 'entry' : 'entries'}'
            '${insight.amount == null ? '' : ' · ${formatMoney(insight.amount!)}'}',
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              if (insight.rule == InsightRule.possibleSubscription &&
                  onAddAsBill != null)
                TextButton(
                  onPressed: () => onAddAsBill!(insight),
                  child: const Text('Add as bill'),
                ),
              TextButton(
                onPressed: () => onOpen(insight),
                child: const Text('View entries'),
              ),
              TextButton(
                onPressed: () => onSnooze(insight),
                child: const Text('Snooze'),
              ),
              TextButton(
                onPressed: () => onDismiss(insight),
                child: const Text('Dismiss'),
              ),
              TextButton(
                onPressed: () => onDisableRule(insight.rule),
                child: const Text('Turn off'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
