import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

/// Savings goals and sinking funds (BUD 04, BUD 05).
///
/// Distinguishes money allocated to a goal from money actually moved to its
/// account, and flags reservations that are not backed by real money.
class GoalsView extends StatelessWidget {
  const GoalsView({super.key, required this.progress, required this.onOpen});

  final List<GoalProgress> progress;
  final ValueChanged<GoalProgress> onOpen;

  @override
  Widget build(BuildContext context) {
    if (progress.isEmpty) {
      return const Center(child: Text('No savings goals yet'));
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final p in progress)
          Card(
            child: InkWell(
              onTap: () => onOpen(p),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.goal.name,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          '${formatMoney(p.allocated)} of ${formatMoney(p.goal.target)}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: p.goal.target.isZero
                          ? 0
                          : (p.allocated.minor / p.goal.target.minor).clamp(
                              0.0,
                              1.0,
                            ),
                      semanticsLabel: '${p.goal.name} progress',
                      semanticsValue: p.goal.target.isZero
                          ? '0'
                          : '${(p.allocated.minor * 100 ~/ p.goal.target.minor).clamp(0, 100)}',
                    ),
                    const SizedBox(height: 8),
                    if (p.goal.targetDate != null)
                      Text('Target date ${formatDate(p.goal.targetDate!)}'),
                    Text(
                      'Moved to savings ${formatMoney(p.moved)}'
                      '${p.notYetMoved.isPositive ? ' · ${formatMoney(p.notYetMoved)} allocated but not yet moved' : ''}',
                    ),
                    if (p.goal.kind == GoalKind.sinkingFund)
                      Text(
                        'Reserved ${formatMoney(p.reserved)} · '
                        'funding gap ${formatMoney(p.fundingGap)}',
                      ),
                    if (p.unfundedReservation.isPositive)
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_outlined,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${formatMoney(p.unfundedReservation)} reserved here is '
                              'also reserved elsewhere and is not covered by money held',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
