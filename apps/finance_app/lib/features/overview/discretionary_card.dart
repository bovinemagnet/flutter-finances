import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/section_label.dart';
import '../../app/theme.dart';
import '../../format/formatters.dart';
import 'overview_widgets.dart';
import 'spending_pace.dart';

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
    this.pace,
  });

  final DiscretionaryEstimate estimate;
  final String Function(String accountId) accountName;

  /// Spending against the current budget period, shown as a bar.
  final SpendingPace? pace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = FinancePalette.of(context);
    final warning = TextStyle(color: palette.negative);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: palette.accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const SectionLabel('Available until payday'),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      'Until ${formatDate(estimate.horizonEnd)}',
                      style: palette.figure(
                        size: 11,
                        weight: FontWeight.w500,
                        color: palette.accentText,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMoney(estimate.estimate),
                style: palette.figure(size: 40),
              ),
            ),
            if (!estimate.complete)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Incomplete estimate. Missing: ${estimate.missingInputs.map((i) => describeMissingInput(i, accountName)).join(', ')}',
                  style: warning,
                ),
              ),
            if (estimate.shortfall.isPositive)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_outlined, color: palette.negative),
                    const SizedBox(width: 4),
                    Text(
                      'Shortfall ${formatMoney(estimate.shortfall)}',
                      style: warning,
                    ),
                  ],
                ),
              ),
            if (pace != null) ...[
              const SizedBox(height: 12),
              BudgetBar(pace: pace!),
            ],
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: Text(
                  'How this is worked out',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.accentText,
                  ),
                ),
                children: [
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
                  const Text('The estimate is the smaller of the two.'),
                  Text(
                    'Only confirmed income is counted.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
