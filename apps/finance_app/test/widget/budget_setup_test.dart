import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/onboarding/onboarding_model.dart';
import 'package:finance_app/screens/pages/budget_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async => dir = await Directory.systemTemp.createTemp('budget'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  /// A workspace whose owner skipped the budget step during setup.
  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
      await state.applyOnboarding(
        OnboardingModel(today: LocalDate(2026, 11, 4)).build(),
      );
    });
    tester.view.physicalSize = const Size(411, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(
          home: Scaffold(body: BudgetPage(onOpenEntries: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder save() => find.widgetWithText(FilledButton, 'Save budget');

  testWidgets('a budget skipped during setup can be set up later', (
    tester,
  ) async {
    await pump(tester);
    final categoryCount = state.chart.categories.length;
    expect(find.textContaining('in Settings'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Set up budget'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take-home pay'),
      '3000',
    );
    await tester.pump();
    await tester.ensureVisible(save());
    await tester.tap(save());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    final plan = state.budgetPlan!;
    expect(plan.versions.single.income, Money(300000, Currency.aud));
    expect(state.chart.categories.length, categoryCount);
    final ids = {for (final c in state.chart.categories) c.id};
    expect(plan.versions.single.allocations, isNotEmpty);
    for (final allocation in plan.versions.single.allocations) {
      expect(ids, contains(allocation.targetId));
    }
    expect(find.text('Set up budget'), findsNothing);
    expect(find.textContaining('No budget yet'), findsNothing);
  });

  testWidgets('a budget cannot be saved without take-home pay', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Set up budget'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(save());
    expect(tester.widget<FilledButton>(save()).onPressed, isNull);
  });

  testWidgets('a payday after today still shows the saved budget', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Set up budget'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take-home pay'),
      '3000',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(save());
    await tester.tap(save());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Set up budget'), findsNothing);
  });
}
