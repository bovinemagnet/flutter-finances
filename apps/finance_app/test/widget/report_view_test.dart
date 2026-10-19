import 'package:finance_app/features/reports/report_view.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
