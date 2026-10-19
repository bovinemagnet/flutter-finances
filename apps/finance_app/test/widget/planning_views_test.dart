import 'package:finance_app/features/budget/budget_view.dart';
import 'package:finance_app/features/overview/discretionary_card.dart';
import 'package:finance_app/features/overview/insight_list.dart';
import 'package:finance_app/features/plan/forecast_view.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/sample_world.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  final world = SampleWorld();

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets('budget view shows remaining, overspend and pending separately', (
    tester,
  ) async {
    final opened = <List<String>>[];
    await pump(
      tester,
      BudgetView(
        evaluation: world.evaluation(),
        nameFor: world.nameFor,
        onOpenEntries: opened.add,
      ),
    );
    expect(find.text(r'$350.00 left'), findsOneWidget); // groceries 800 - 450
    expect(find.text(r'$20.00 over'), findsOneWidget); // dining 300 - 320
    expect(find.textContaining(r'$25.00 pending'), findsOneWidget);
    expect(
      find.text(r'$2,200.00 of income is not yet assigned'),
      findsOneWidget,
    );
    await tester.tap(find.text('Dining'));
    expect(opened.single, hasLength(2));
  });

  testWidgets('discretionary card explains its limits', (tester) async {
    await pump(
      tester,
      DiscretionaryCard(estimate: world.estimate(), accountName: world.nameFor),
    );
    expect(find.text('Available for discretionary spending'), findsOneWidget);
    expect(find.textContaining('Budget limit:'), findsOneWidget);
    expect(find.textContaining('Cash limit:'), findsOneWidget);
    expect(find.text('Only confirmed income is counted.'), findsOneWidget);
  });

  testWidgets('forecast offers a table alternative with certainty labels', (
    tester,
  ) async {
    await pump(tester, ForecastView(forecast: world.forecast()));
    expect(find.textContaining('Lowest balance'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Forecast chart')), findsOneWidget);
    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    expect(find.text('Actual'), findsWidgets);
  });

  testWidgets('insights explain themselves and can be turned off', (
    tester,
  ) async {
    final insights = generateInsights(
      period: DateRange(LocalDate(2026, 10, 1), LocalDate(2026, 10, 31)),
      budget: world.evaluation(),
      unreviewedJournalIds: {world.journals[1].id},
    );
    final disabled = <InsightRule>[];
    await pump(
      tester,
      InsightList(
        insights: insights,
        onOpen: (_) {},
        onDismiss: (_) {},
        onSnooze: (_) {},
        onDisableRule: disabled.add,
      ),
    );
    expect(find.text('Over budget'), findsOneWidget);
    expect(find.text('Transactions to review'), findsOneWidget);
    await tester.tap(find.text('Turn off').first);
    expect(disabled, isNotEmpty);
  });

  testWidgets('every insight rule has a title', (tester) async {
    final period = DateRange(LocalDate(2026, 10, 1), LocalDate(2026, 10, 31));
    await pump(
        tester,
        InsightList(
          insights: [
            for (final rule in InsightRule.values)
              Insight(key: rule.name, rule: rule, trigger: 't', entryIds: const [], period: period),
          ],
          onOpen: (_) {},
          onDismiss: (_) {},
          onSnooze: (_) {},
          onDisableRule: (_) {},
        ));
    expect(find.text('Possible subscription'), findsOneWidget);
    expect(find.text('Unusual purchase'), findsOneWidget);
    expect(find.text('Spending spike'), findsOneWidget);
  });
}
