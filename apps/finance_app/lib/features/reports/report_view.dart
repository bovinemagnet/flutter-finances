import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/breakpoints.dart';
import '../../format/formatters.dart';

/// A report as a bar chart with an accessible table beside it (REP 01).
///
/// Every row drills through to its source entries. The chart is decorative
/// for assistive technology; each bar carries a text label and the table
/// holds the same figures.
class ReportView extends StatelessWidget {
  const ReportView({
    super.key,
    required this.report,
    required this.onDrillThrough,
    this.chartColumn,
  });

  final Report report;
  final ValueChanged<List<String>> onDrillThrough;

  /// Money column to chart; defaults to the first money column.
  final String? chartColumn;

  ReportColumn? get _chartColumn {
    final money = report.columns
        .where((c) => c.kind == ReportValueKind.money)
        .toList();
    if (money.isEmpty) return null;
    return money.firstWhere(
      (c) => c.key == chartColumn,
      orElse: () => money.first,
    );
  }

  String _cell(ReportRow row, ReportColumn column) => switch (column.kind) {
    ReportValueKind.money =>
      row.amounts[column.key] == null
          ? '–'
          : formatMoney(row.amounts[column.key]!),
    ReportValueKind.count => '${row.counts[column.key] ?? 0}',
  };

  @override
  Widget build(BuildContext context) {
    final wide =
        windowClassFor(MediaQuery.sizeOf(context).width) ==
        WindowClass.expanded;
    final chart = _chartColumn == null
        ? const SizedBox.shrink()
        : _BarChart(
            report: report,
            column: _chartColumn!,
            onTap: onDrillThrough,
          );
    final table = _table(context);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(report.title, style: Theme.of(context).textTheme.titleLarge),
        if (report.range != null) Text(report.range!.label),
        if (report.asOf != null) Text('As at ${formatDate(report.asOf!)}'),
        if (report.includesUnsyncedChanges)
          const Chip(
            avatar: Icon(Icons.cloud_off_outlined, size: 18),
            label: Text('Includes changes not yet synced'),
          ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        header,
        const SizedBox(height: 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: chart),
              const SizedBox(width: 24),
              Expanded(child: table),
            ],
          )
        else ...[
          chart,
          const SizedBox(height: 16),
          table,
        ],
      ],
    );
  }

  Widget _table(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        showCheckboxColumn: false,
        columns: [
          DataColumn(label: Text(report.keyLabel)),
          for (final column in report.columns)
            DataColumn(label: Text(column.label), numeric: true),
        ],
        rows: [
          for (final row in report.rows)
            DataRow(
              onSelectChanged: row.journalIds.isEmpty
                  ? null
                  : (_) => onDrillThrough(row.journalIds),
              cells: [
                DataCell(Text(row.label)),
                for (final column in report.columns)
                  DataCell(Text(_cell(row, column))),
              ],
            ),
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.report,
    required this.column,
    required this.onTap,
  });

  final Report report;
  final ReportColumn column;
  final ValueChanged<List<String>> onTap;

  @override
  Widget build(BuildContext context) {
    final values = [
      for (final row in report.rows) row.amounts[column.key]?.minor.abs() ?? 0,
    ];
    final max = values.fold<int>(0, (a, b) => a > b ? a : b);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, row) in report.rows.indexed)
          Semantics(
            button: row.journalIds.isNotEmpty,
            label:
                '${row.label} ${row.amounts[column.key] == null ? '' : formatMoney(row.amounts[column.key]!)}',
            excludeSemantics: true,
            child: InkWell(
              onTap: row.journalIds.isEmpty
                  ? null
                  : () => onTap(row.journalIds),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(row.label, overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final fraction = max == 0 ? 0.0 : values[index] / max;
                          final negative =
                              row.amounts[column.key]?.isNegative ?? false;
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 20,
                              width: constraints.maxWidth * fraction,
                              decoration: BoxDecoration(
                                color: negative ? scheme.error : scheme.primary,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      row.amounts[column.key] == null
                          ? ''
                          : formatMoney(row.amounts[column.key]!),
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
