import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/shell.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/pages/overview_page.dart';
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
  late List<Destination> visited;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('checklist');
    visited = [];
  });
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function()? seed,
  }) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
      await seed?.call();
    });
    tester.view.physicalSize = const Size(411, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(
          home: Scaffold(
            body: OverviewPage(onNavigate: visited.add, onOpenEntries: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addAccount() => state.store.createAccount(
    const Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
  );

  Future<void> addBudget() => state.savePlan(
    BudgetPlan(
      id: 'plan',
      name: 'Household',
      mode: BudgetMode.categoryOnly,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: LocalDate(2026, 11, 1),
        timezone: 'Australia/Brisbane',
      ),
      versions: [
        BudgetVersion(
          id: 'v1',
          effectiveFrom: LocalDate(2026, 11, 1),
          income: Money(500000, Currency.aud),
        ),
      ],
    ),
  );

  /// Lets the store's write finish, then the page rebuild.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('a new workspace sees its next steps, not an all-clear', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('FINISH SETTING UP'), findsOneWidget);
    expect(find.text('0 of 3 done'), findsOneWidget);
    expect(find.text('Add an account'), findsOneWidget);
    expect(find.text('Set up a budget'), findsOneWidget);
    expect(find.text('Set a minimum cash buffer'), findsOneWidget);
    expect(find.text('Nothing needs attention'), findsNothing);
  });

  testWidgets('steps open the place that completes them', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add an account'));
    await tester.tap(find.text('Set up a budget'));
    expect(visited, [Destination.accounts, Destination.budget]);
  });

  testWidgets('setting the buffer from its step completes the step', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Set a minimum cash buffer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '500');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a completed step is marked in words and cannot be tapped', (
    tester,
  ) async {
    await pump(tester, seed: addAccount);
    expect(find.text('1 of 3 done'), findsOneWidget);
    await tester.tap(find.text('Add an account'));
    expect(visited, isEmpty);
  });

  testWidgets('the card goes away when everything is done', (tester) async {
    await pump(
      tester,
      seed: () async {
        await addAccount();
        await addBudget();
        await state.setMinimumBuffer(Money(50000, Currency.aud));
      },
    );
    expect(find.text('FINISH SETTING UP'), findsNothing);
    expect(find.text('Nothing needs attention'), findsOneWidget);
  });

  testWidgets('the card can be hidden, and stays hidden', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Hide'));
    await settle(tester);
    expect(find.text('FINISH SETTING UP'), findsNothing);
    expect(state.setupChecklistHidden, isTrue);
  });

  testWidgets('hiding it does not bring back a false all-clear', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Hide'));
    await settle(tester);
    expect(find.text('Nothing needs attention'), findsNothing);
  });
}
