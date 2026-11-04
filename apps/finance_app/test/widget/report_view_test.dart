import 'package:finance_app/features/reports/report_view.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  Money m(int minor) => Money(minor, Currency.aud);
  final report = Report(
    title: 'Spending by category',
    keyLabel: 'Category',
    columns: const [ReportColumn('spent', 'Spent')],
    rows: [
      ReportRow(
        key: 'groceries',
        label: 'Groceries',
        amounts: {'spent': m(12050)},
        journalIds: const ['j1', 'j2'],
      ),
      ReportRow(
        key: 'fuel',
        label: 'Fuel',
        amounts: {'spent': m(4000)},
        journalIds: const ['j3'],
      ),
    ],
    includesUnsyncedChanges: true,
  );

  testWidgets('shows a table beside the chart and drills through to entries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportView(report: report, onDrillThrough: opened.add),
        ),
      ),
    );
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text(r'$120.50'), findsNWidgets(2));
    expect(find.text('Includes changes not yet synced'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Groceries \$120\.50')), findsWidgets);
    await tester.tap(find.text('Groceries').last);
    expect(opened.single, ['j1', 'j2']);
  });

  Future<void> pumpReport(WidgetTester tester, Report report) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportView(report: report, onDrillThrough: (_) {})),
      ),
    );
  }

  testWidgets('a period is shown as Australian dates', (tester) async {
    await pumpReport(
      tester,
      Report(
        title: 'Spending by category',
        keyLabel: 'Category',
        columns: const [ReportColumn('spent', 'Spent')],
        rows: const [],
        range: DateRange(LocalDate(2026, 11, 1), LocalDate(2026, 11, 30)),
      ),
    );
    expect(find.text('1 Nov 2026 to 30 Nov 2026'), findsOneWidget);
  });

  testWidgets('a financial year keeps its short name', (tester) async {
    await pumpReport(
      tester,
      Report(
        title: 'Spending by category',
        keyLabel: 'Category',
        columns: const [ReportColumn('spent', 'Spent')],
        rows: const [],
        range: DateRange.financialYear(2026),
      ),
    );
    expect(find.text('FY2026-27'), findsOneWidget);
  });

  testWidgets('a report with no rows says so instead of an empty table', (
    tester,
  ) async {
    await pumpReport(
      tester,
      Report(
        title: 'Spending by category',
        keyLabel: 'Category',
        columns: const [ReportColumn('spent', 'Spent')],
        rows: const [],
      ),
    );
    expect(find.text('Nothing to report yet'), findsOneWidget);
    expect(find.byType(DataTable), findsNothing);
  });
}
