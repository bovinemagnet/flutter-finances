import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

const _missingLabels = {
  'budget': 'a budget for this period',
  'minimumBuffer': 'a minimum cash buffer',
};

String describeMissingInput(String input, String Function(String) accountName) {
  if (_missingLabels.containsKey(input)) return _missingLabels[input]!;
  if (input.startsWith('staleAccountData:')) {
    return 'up-to-date data for ${accountName(input.split(':').last)}';
  }
  if (input.startsWith('accountData:')) {
    return 'data for ${accountName(input.split(':').last)}';
  }
  return input;
}

/// Explainable estimate of discretionary money until the next payday
/// (BUD 07): the smaller of the budget and cash limits, with the horizon,
/// data freshness, any shortfall and any missing inputs stated.
class DiscretionaryCard extends StatelessWidget {
  const DiscretionaryCard({
    super.key,
    required this.estimate,
    required this.accountName,
  });

  final DiscretionaryEstimate estimate;
  final String Function(String accountId) accountName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Available for discretionary spending',
              style: theme.textTheme.titleMedium,
            ),
            Text('Until ${formatDate(estimate.horizonEnd)}'),
            const SizedBox(height: 8),
            Text(
              formatMoney(estimate.estimate),
              style: theme.textTheme.displaySmall,
            ),
            if (!estimate.complete)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Incomplete estimate. Missing: ${estimate.missingInputs.map((i) => describeMissingInput(i, accountName)).join(', ')}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (estimate.shortfall.isPositive)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Shortfall ${formatMoney(estimate.shortfall)}',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ),
              ),
            const Divider(),
            Text(
              'Budget limit: ${estimate.budgetLimit == null ? 'no budget' : formatMoney(estimate.budgetLimit!)}',
            ),
            Text(
              'Cash limit: ${formatMoney(estimate.cashLimit)} (lowest balance ${formatMoney(estimate.lowestBalance)} on ${formatDate(estimate.lowestBalanceDate)}, after a ${formatMoney(estimate.minimumBuffer)} buffer)',
            ),
            if (estimate.sourceFreshness != null)
              Text(
                'Account data as at ${formatDate(estimate.sourceFreshness!)}',
              ),
            Text(
              'Only confirmed income is counted.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
