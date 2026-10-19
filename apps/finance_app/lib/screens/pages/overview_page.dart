import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/shell.dart';
import '../../features/overview/discretionary_card.dart';
import '../../features/overview/insight_list.dart';
import '../../format/formatters.dart';

/// Overview: calculated balances with trust cues, the discretionary
/// estimate, upcoming bills and explainable insights.
class OverviewPage extends StatelessWidget {
  const OverviewPage({
    super.key,
    required this.onNavigate,
    required this.onOpenEntries,
    this.receiptJournalIds = const {},
  });

  final ValueChanged<Destination> onNavigate;
  final ValueChanged<List<String>> onOpenEntries;
  final Set<String> receiptJournalIds;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ledger = state.ledger;
    final today = state.today();
    final upcoming = state
        .occurrenceStates(today, today.addDays(7))
        .where((s) => s.outstanding.isPositive)
        .toList();
    final theme = Theme.of(context);
    final reminder = state.backupReminder();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (reminder != null)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: Text(reminder),
              subtitle: const Text(
                'An encrypted backup is the only way to recover data kept on this device.',
              ),
              trailing: TextButton(
                onPressed: () => onNavigate(Destination.settings),
                child: const Text('Back up'),
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your money', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                _Figure('Available cash', formatMoney(ledger.liquidMoney())),
                _Figure(
                  'Owed on cards and loans',
                  formatMoney(ledger.liabilitiesOwed()),
                ),
                _Figure('Net worth', formatMoney(ledger.netWorth())),
                const SizedBox(height: 8),
                Text(
                  'Calculated from your entries'
                  '${state.unsyncedCount == 0 ? '' : ' · ${state.unsyncedCount} changes not yet synced'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        DiscretionaryCard(
          estimate: state.discretionary(),
          accountName: (id) =>
              state.chart.hasAccount(id) ? state.chart.account(id).name : id,
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.event_note_outlined),
            title: Text(
              upcoming.isEmpty
                  ? 'No bills due in the next 7 days'
                  : '${upcoming.length} ${upcoming.length == 1 ? 'bill' : 'bills'} due in the next 7 days',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onNavigate(Destination.plan),
          ),
        ),
        const SizedBox(height: 8),
        Text('Needs attention', style: theme.textTheme.titleMedium),
        InsightList(
          insights: state.insights(receiptJournalIds: receiptJournalIds),
          onOpen: (insight) => onOpenEntries(insight.entryIds),
          onDismiss: state.dismissInsight,
          onSnooze: state.snoozeInsight,
          onDisableRule: (rule) => state.setRuleEnabled(rule, false),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.insights_outlined),
              label: const Text('Reports'),
              onPressed: () => onNavigate(Destination.reports),
            ),
            ActionChip(
              avatar: const Icon(Icons.account_balance_outlined),
              label: const Text('Accounts'),
              onPressed: () => onNavigate(Destination.accounts),
            ),
            ActionChip(
              avatar: const Icon(Icons.settings_outlined),
              label: const Text('Settings'),
              onPressed: () => onNavigate(Destination.settings),
            ),
          ],
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    ),
  );
}
