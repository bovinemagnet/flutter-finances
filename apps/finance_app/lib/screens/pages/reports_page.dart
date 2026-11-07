import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../features/reports/report_view.dart';
import '../../platform/services.dart';

enum ReportKind {
  incomeVsExpenses('Income and expenses'),
  byCategory('Spending by category'),
  byPayee('Spending by merchant'),
  byTag('Spending by tag'),
  budgetVsActual('Budget and actual'),
  balances('Account balances'),
  netWorth('Net worth history'),
  cashFlow('Cash flow'),
  receipts('Receipt coverage'),
  goals('Goals');

  const ReportKind(this.label);
  final String label;
}

enum RangeChoice {
  thisMonth('This month'),
  thisFinancialYear('This financial year'),
  lastFinancialYear('Last financial year'),
  thisCalendarYear('This calendar year');

  const RangeChoice(this.label);
  final String label;

  DateRange dateRange(LocalDate today) => switch (this) {
    thisMonth => DateRange(
      LocalDate(today.year, today.month, 1),
      LocalDate(
        today.year,
        today.month,
        LocalDate.daysInMonth(today.year, today.month),
      ),
    ),
    thisFinancialYear => DateRange.financialYearContaining(today),
    lastFinancialYear => DateRange.financialYearContaining(
      today.addMonths(-12),
    ),
    thisCalendarYear => DateRange.calendarYear(today.year),
  };
}

/// Reports with date filters, accessible tables and drill-through (REP 01,
/// REP 02). Every report uses the same ledger definitions as the overview.
class ReportsPage extends StatefulWidget {
  const ReportsPage({
    super.key,
    required this.onOpenEntries,
    this.receiptJournalIds = const {},
  });

  final ValueChanged<List<String>> onOpenEntries;
  final Set<String> receiptJournalIds;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  var _kind = ReportKind.byCategory;
  var _range = RangeChoice.thisMonth;

  Future<void> _export(BuildContext context, Report report) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await services.fileExporter.exportFile(
        reportExportName(report, today: state.today()),
        (file) => file.writeAsString(exportReportAsCsv(report)),
      );
      if (outcome == ExportOutcome.cancelled) return;
      messenger.showSnackBar(const SnackBar(content: Text('Report exported')));
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ledger = state.ledger;
    final range = _range.dateRange(state.today());
    final unsynced =
        state.settings.syncMode == SyncMode.synced && state.unsyncedCount > 0;
    final evaluation = state.budgetEvaluation();
    final report = switch (_kind) {
      ReportKind.incomeVsExpenses => incomeVsExpenses(
        ledger,
        range,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.byCategory => spendingByCategory(
        ledger,
        range,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.byPayee => spendingByPayee(
        ledger,
        range,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.byTag => spendingByTag(
        ledger,
        range,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.budgetVsActual =>
        evaluation == null
            ? null
            : budgetVsActual(
                evaluation,
                labels: {
                  for (final c in state.chart.categories) c.id: c.name,
                  for (final g in state.goals) g.id: g.name,
                },
                includesUnsyncedChanges: unsynced,
              ),
      ReportKind.balances => accountBalances(
        ledger,
        asOf: range.end,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.netWorth => netWorthHistory(
        ledger,
        range,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.cashFlow => cashFlow(
        ledger,
        range,
        accountIds: {
          for (final a in state.chart.accounts)
            if (a.type.isLiquid) a.id,
        },
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.receipts => receiptCoverage(
        ledger,
        range,
        receiptJournalIds: widget.receiptJournalIds,
        includesUnsyncedChanges: unsynced,
      ),
      ReportKind.goals => goalProgressReport(
        state.goalProgress(),
        includesUnsyncedChanges: unsynced,
      ),
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownMenu<ReportKind>(
                initialSelection: _kind,
                label: const Text('Report'),
                dropdownMenuEntries: [
                  for (final k in ReportKind.values)
                    DropdownMenuEntry(value: k, label: k.label),
                ],
                onSelected: (k) => setState(() => _kind = k ?? _kind),
              ),
              DropdownMenu<RangeChoice>(
                initialSelection: _range,
                label: const Text('Period'),
                dropdownMenuEntries: [
                  for (final r in RangeChoice.values)
                    DropdownMenuEntry(value: r, label: r.label),
                ],
                onSelected: (r) => setState(() => _range = r ?? _range),
              ),
              OutlinedButton.icon(
                onPressed: report == null || report.rows.isEmpty
                    ? null
                    : () => _export(context, report),
                icon: const Icon(Icons.download_outlined),
                label: const Text('Export CSV'),
              ),
            ],
          ),
        ),
        Expanded(
          child: report == null
              ? const Center(
                  child: Text('Set up a budget to compare budget and actual'),
                )
              : ReportView(
                  report: report,
                  onDrillThrough: widget.onOpenEntries,
                ),
        ),
      ],
    );
  }
}
