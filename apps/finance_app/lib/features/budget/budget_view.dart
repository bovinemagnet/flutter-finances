import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

/// Budget and actual amounts together for one period (BUD 01, BUD 03).
///
/// Pending spending is shown separately, and unassigned or over-allocated
/// income is stated explicitly rather than netted away.
class BudgetView extends StatelessWidget {
  const BudgetView({
    super.key,
    required this.evaluation,
    required this.nameFor,
    required this.onOpenEntries,
  });

  final BudgetPeriodEvaluation evaluation;
  final String Function(String targetId) nameFor;
  final ValueChanged<List<String>> onOpenEntries;

  @override
  Widget build(BuildContext context) {
    final summary = evaluation.summary;
    final period = evaluation.period;
    final grouped = <String?, List<BudgetLine>>{};
    for (final line in evaluation.lines) {
      grouped.putIfAbsent(line.groupId, () => []).add(line);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${formatDate(period.start)} to ${formatDate(period.end)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (evaluation.version == null)
          const _Banner(
            icon: Icons.info_outline,
            text: 'No budget covers this period yet.',
          ),
        if (summary != null && summary.overAllocated.isPositive)
          _Banner(
            icon: Icons.warning_amber_outlined,
            text: 'Over-allocated by ${formatMoney(summary.overAllocated)}',
            error: true,
          ),
        if (summary != null && summary.unassigned.isPositive)
          _Banner(
            icon: Icons.savings_outlined,
            text:
                '${formatMoney(summary.unassigned)} of income is not yet assigned',
          ),
        for (final group in evaluation.groups) ...[
          const SizedBox(height: 16),
          _GroupHeader(group: group),
          for (final line in grouped[group.groupId] ?? const <BudgetLine>[])
            _LineTile(
              line: line,
              name: nameFor(line.targetId),
              onOpen: onOpenEntries,
            ),
        ],
        if (grouped[null] != null) ...[
          const SizedBox(height: 16),
          Text(
            'Other categories',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final line in grouped[null]!)
            _LineTile(
              line: line,
              name: nameFor(line.targetId),
              onOpen: onOpenEntries,
            ),
        ],
        if (evaluation.unbudgeted.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Spending without a budget',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final line in evaluation.unbudgeted)
            _LineTile(
              line: line,
              name: nameFor(line.targetId),
              onOpen: onOpenEntries,
            ),
        ],
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: error ? scheme.errorContainer : scheme.secondaryContainer,
      child: ListTile(leading: Icon(icon), title: Text(text)),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});
  final BudgetGroupLine group;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Text(
              group.group.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Text('${formatMoney(group.actual)} of ${formatMoney(group.planned)}'),
        ],
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.name,
    required this.onOpen,
  });
  final BudgetLine line;
  final String name;
  final ValueChanged<List<String>> onOpen;

  @override
  Widget build(BuildContext context) {
    final available = line.planned + line.openingRollover + line.adjustments;
    final over = line.remaining.isNegative;
    final fraction = available.minor <= 0
        ? (line.postedNet.isPositive ? 1.0 : 0.0)
        : (line.postedNet.minor / available.minor).clamp(0.0, 1.0);
    final status = over
        ? '${formatMoney(-line.remaining)} over'
        : '${formatMoney(line.remaining)} left';
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: line.journalIds.isEmpty && line.pendingJournalIds.isEmpty
          ? null
          : () => onOpen([...line.journalIds, ...line.pendingJournalIds]),
      title: Row(
        children: [
          Expanded(child: Text(name)),
          if (over) Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 4),
          Text(status, style: TextStyle(color: over ? scheme.error : null)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: fraction,
            color: over ? scheme.error : null,
            semanticsLabel: '$name spending',
            semanticsValue: '${(fraction * 100).round()}',
          ),
          const SizedBox(height: 4),
          Text(
            [
              'Spent ${formatMoney(line.postedNet)} of ${formatMoney(available)}',
              if (!line.openingRollover.isZero)
                'includes ${formatMoney(line.openingRollover, signed: true)} rolled over',
              if (line.pending.isPositive)
                '${formatMoney(line.pending)} pending, ${formatMoney(line.remainingAfterPending)} after pending',
            ].join(' · '),
          ),
        ],
      ),
    );
  }
}
