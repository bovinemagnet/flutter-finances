import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/section_label.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/app_state.dart';
import '../../features/overview/discretionary_card.dart';
import '../../features/overview/insight_list.dart';
import '../../features/overview/overview_widgets.dart';
import '../../features/overview/spending_pace.dart';
import '../../features/transactions/transaction_list.dart';
import '../../format/formatters.dart';
import '../editors.dart';

/// Content wider than this gets the two-column dashboard.
const overviewDashboardWidth = 960.0;

/// Overview: calculated balances with trust cues, the discretionary
/// estimate, upcoming bills and explainable insights. Wide windows add the
/// spending chart and recent entries in a two-column dashboard.
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
    final estimate = state.discretionary();
    final evaluation = state.budgetEvaluation();
    final pace = evaluation == null
        ? null
        : spendingPace(evaluation, ledger, today);
    final paced = pace != null && pace.budget.isPositive ? pace : null;
    final schedules = {for (final s in state.schedules) s.id: s};
    final billsBeforePayday = state
        .occurrenceStates(today, estimate.horizonEnd)
        .where(
          (s) =>
              s.outstanding.isPositive &&
              schedules[s.occurrence.scheduleId]?.kind != ScheduleKind.income,
        )
        .toList();
    final palette = FinancePalette.of(context);

    final hero = DiscretionaryCard(
      estimate: estimate,
      pace: paced,
      accountName: (id) =>
          state.chart.hasAccount(id) ? state.chart.account(id).name : id,
    );
    final netWorth = FigureTile(
      label: 'Net worth',
      value: formatMoney(ledger.netWorth()),
    );
    final bills = FigureTile(
      label: 'Bills before payday',
      value: formatMoney(
        billsBeforePayday.fold(
          Money.zero(state.currency),
          (total, s) => total + s.outstanding,
        ),
      ),
      caption:
          '${billsBeforePayday.length} due by ${formatDate(estimate.horizonEnd)}',
    );
    final attention = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: SectionLabel('Needs attention'),
        ),
        InsightList(
          insights: state.insights(receiptJournalIds: receiptJournalIds),
          onOpen: (insight) => onOpenEntries(insight.entryIds),
          onDismiss: state.dismissInsight,
          onSnooze: state.snoozeInsight,
          onDisableRule: (rule) => state.setRuleEnabled(rule, false),
          onAddAsBill: (insight) async {
            final proposal = state
                .subscriptionProposals()
                .where((p) => p.journalIds.any(insight.entryIds.contains))
                .firstOrNull;
            if (proposal != null) await state.confirmSubscription(proposal);
          },
        ),
      ],
    );
    final money = _YourMoney(state: state, onNavigate: onNavigate);
    final comingUp = _ComingUp(
      state: state,
      schedules: schedules,
      onNavigate: onNavigate,
    );
    final reminder = state.backupReminder();
    final backup = reminder == null
        ? null
        : Card(
            margin: EdgeInsets.zero,
            color: palette.warningSoft,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: palette.warningLine),
            ),
            child: ListTile(
              iconColor: palette.onWarningSoft,
              textColor: palette.onWarningSoft,
              leading: const Icon(Icons.backup_outlined),
              title: Text(reminder),
              subtitle: const Text(
                'An encrypted backup is the only way to recover data kept on this device.',
              ),
              trailing: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: palette.onWarningSoft,
                ),
                onPressed: () => onNavigate(Destination.settings),
                child: const Text('Back up'),
              ),
            ),
          );
    const gap = SizedBox(height: 16);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < overviewDashboardWidth) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              if (backup != null) ...[backup, gap],
              hero,
              gap,
              FigureRow(children: [netWorth, bills]),
              gap,
              money,
              gap,
              comingUp,
              gap,
              attention,
              gap,
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
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
          children: [
            if (backup != null) ...[backup, gap],
            FigureRow(
              minTileWidth: 200,
              children: [
                netWorth,
                if (paced != null)
                  FigureTile(
                    label: 'Spent this period',
                    value: formatMoney(paced.spent),
                    caption:
                        'of ${formatMoney(paced.budget)} budget · '
                        '${paced.spent > paced.paceToday ? 'ahead of pace' : 'on pace'}',
                    captionColour: paced.spent > paced.paceToday
                        ? palette.negative
                        : palette.accentText,
                  ),
                bills,
                FigureTile(
                  label: 'Owed on cards and loans',
                  value: formatMoney(ledger.liabilitiesOwed()),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (paced != null) ...[
                        SpendingPaceChart(pace: paced),
                        const SizedBox(height: 20),
                      ],
                      _RecentEntries(
                        state: state,
                        receiptJournalIds: receiptJournalIds,
                        onNavigate: onNavigate,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [hero, gap, attention, gap, money, gap, comingUp],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _YourMoney extends StatelessWidget {
  const _YourMoney({required this.state, required this.onNavigate});

  final AppState state;
  final ValueChanged<Destination> onNavigate;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final ledger = state.ledger;
    return OverviewSection(
      title: 'Your money',
      action: 'Accounts',
      onAction: () => onNavigate(Destination.accounts),
      children: [
        for (final account in state.chart.accounts)
          if (!account.archived)
            Builder(
              builder: (context) {
                final shown = ledger.displayBalance(account.id);
                final signed = account.type.isLiability ? -shown : shown;
                return FigureRowTile(
                  title: account.name,
                  subtitle: account.lastReconciledOn == null
                      ? null
                      : 'Reconciled ${formatDate(account.lastReconciledOn!)}',
                  amount: formatMoney(signed),
                  amountColour: signed.isNegative ? palette.negative : null,
                );
              },
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Text(
            'Calculated from your entries'
            '${state.unsyncedCount == 0 ? '' : ' · ${state.unsyncedCount} changes not yet synced'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ComingUp extends StatelessWidget {
  const _ComingUp({
    required this.state,
    required this.schedules,
    required this.onNavigate,
  });

  final AppState state;
  final Map<String, RecurringSchedule> schedules;
  final ValueChanged<Destination> onNavigate;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final today = state.today();
    final upcoming =
        state
            .occurrenceStates(today, today.addDays(7))
            .where((s) => s.outstanding.isPositive)
            .toList()
          ..sort(
            (a, b) => a.occurrence.dueDate.compareTo(b.occurrence.dueDate),
          );
    return OverviewSection(
      title: 'Coming up',
      action: 'Plan',
      onAction: () => onNavigate(Destination.plan),
      children: [
        if (upcoming.isEmpty)
          const ListTile(title: Text('No bills due in the next 7 days')),
        for (final s in upcoming.take(5))
          Builder(
            builder: (context) {
              final schedule = schedules[s.occurrence.scheduleId];
              final income = schedule?.kind == ScheduleKind.income;
              return FigureRowTile(
                leading: DueDate(s.occurrence.dueDate),
                title: schedule?.name ?? 'Scheduled',
                amount: income
                    ? formatMoney(s.outstanding, signed: true)
                    : formatMoney(-s.outstanding),
                amountColour: income ? palette.accentText : null,
                onTap: () => onNavigate(Destination.plan),
              );
            },
          ),
      ],
    );
  }
}

class _RecentEntries extends StatelessWidget {
  const _RecentEntries({
    required this.state,
    required this.receiptJournalIds,
    required this.onNavigate,
  });

  final AppState state;
  final Set<String> receiptJournalIds;
  final ValueChanged<Destination> onNavigate;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final chart = state.chart;
    final journals =
        state.ledger.journals
            .where((j) => j.type != TransactionType.reversal)
            .toList()
          ..sort((a, b) {
            final byDate = b.effectiveDate.compareTo(a.effectiveDate);
            return byDate != 0 ? byDate : b.enteredAt.compareTo(a.enteredAt);
          });
    return OverviewSection(
      title: 'Recent transactions',
      action: 'All transactions',
      onAction: () => onNavigate(Destination.transactions),
      children: [
        if (journals.isEmpty)
          const ListTile(title: Text('No transactions yet')),
        for (final journal in journals.take(6))
          Builder(
            builder: (context) {
              final account =
                  journal.accountId != null &&
                      chart.hasAccount(journal.accountId!)
                  ? chart.account(journal.accountId!).name
                  : '';
              final item = TransactionListItem(
                journal: journal,
                accountName: account,
                categoryLabel: transactionTypeLabels[journal.type]!,
                reviewed: true,
                hasReceipt: receiptJournalIds.contains(journal.id),
                unsynced: false,
              );
              final amount = item.signedAmount;
              final status = switch (journal.status) {
                JournalStatus.pending => ' · Pending',
                JournalStatus.draft => ' · Draft',
                JournalStatus.reversed => ' · Corrected',
                _ => '',
              };
              return FigureRowTile(
                title: journal.payee ?? item.categoryLabel,
                subtitle:
                    '${formatShortDate(journal.effectiveDate)} · $account$status',
                amount: formatMoney(amount, signed: true),
                amountColour: amount.isNegative ? null : palette.accentText,
                onTap: () => openTransactionEditor(context, journal: journal),
              );
            },
          ),
      ],
    );
  }
}
