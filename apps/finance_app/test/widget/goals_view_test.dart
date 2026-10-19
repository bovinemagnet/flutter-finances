import 'package:finance_app/features/goals/goals_view.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/sample_world.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  testWidgets('separates allocated savings from money moved', (tester) async {
    final world = SampleWorld();
    final goal = Goal(
      id: 'g1',
      name: 'Holiday',
      target: Money(300000, Currency.aud),
      targetDate: LocalDate(2027, 6, 1),
    );
    final progress = goalProgress(
      goal,
      ledger: world.ledger,
      allocations: [
        SavingsAllocation(
          id: 'a1',
          goalId: 'g1',
          amount: Money(50000, Currency.aud),
          date: LocalDate(2026, 10, 5),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalsView(progress: [progress], onOpen: (_) {}),
        ),
      ),
    );
    expect(find.text(r'$500.00 of $3,000.00'), findsOneWidget);
    expect(
      find.textContaining(r'$500.00 allocated but not yet moved'),
      findsOneWidget,
    );
    expect(find.text('Target date 1 June 2027'), findsOneWidget);
  });
}
