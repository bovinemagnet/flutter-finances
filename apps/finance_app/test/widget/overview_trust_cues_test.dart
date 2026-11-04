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
const _aud = Currency.aud;

/// UX 03: what a figure is, and how far it can be trusted, is said beside it.
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  late List<Destination> visited;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('trust');
    visited = [];
  });
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  TransactionDraft expense(LocalDate date, {bool pending = false}) =>
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: Money(2000, _aud),
        effectiveDate: date,
        status: pending ? JournalStatus.pending : JournalStatus.posted,
        splits: [Split('groceries', Money(2000, _aud))],
      );

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function()? seed,
  }) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      await store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      await store.createCategory(
        const Category(
          id: 'groceries',
          name: 'Groceries',
          kind: CategoryKind.expense,
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
      await seed?.call();
    });
    tester.view.physicalSize = const Size(411, 2400);
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

  group('freshness', () {
    testWidgets('an account with no entries says so', (tester) async {
      await pump(tester);
      expect(find.textContaining('No entries yet'), findsOneWidget);
    });

    testWidgets('an account shows its latest entry, ignoring future ones', (
      tester,
    ) async {
      await pump(
        tester,
        seed: () async {
          await state.post(expense(LocalDate(2026, 10, 18)));
          await state.post(expense(LocalDate(2026, 11, 2)));
          await state.post(expense(LocalDate(2026, 12, 25)));
        },
      );
      expect(find.textContaining('Last entry 2 Nov 2026'), findsOneWidget);
    });

    testWidgets('the estimate does not claim its data is current', (
      tester,
    ) async {
      await pump(
        tester,
        seed: () => state.post(expense(LocalDate(2026, 10, 18))),
      );
      await tester.tap(find.text('How this is worked out'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Account data as at'), findsNothing);
      expect(find.text('Latest entry 18 Oct 2026'), findsOneWidget);
    });
  });

  group('entries still to review', () {
    testWidgets('are counted beside the balances and open the review', (
      tester,
    ) async {
      await pump(
        tester,
        seed: () async {
          await state.post(expense(LocalDate(2026, 11, 1)));
          await state.post(expense(LocalDate(2026, 11, 2)));
        },
      );
      await tester.tap(find.text('2 entries to review'));
      expect(visited, [Destination.transactions]);
    });

    testWidgets('are not mentioned when there are none', (tester) async {
      await pump(tester);
      expect(find.textContaining('to review'), findsNothing);
    });
  });

  testWidgets('a balance says what pending money it leaves out', (
    tester,
  ) async {
    await pump(
      tester,
      seed: () => state.post(expense(LocalDate(2026, 11, 3), pending: true)),
    );
    expect(find.textContaining(r'Not counting $20.00 pending'), findsOneWidget);
  });

  group('what kind of figure it is', () {
    testWidgets('net worth is calculated, and the hero an estimate', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Calculated from your entries'), findsWidgets);
      expect(find.text('Estimate, not a bank balance'), findsOneWidget);
    });

    testWidgets('bills are planned', (tester) async {
      await pump(
        tester,
        seed: () => state.saveSchedule(
          RecurringSchedule(
            id: 'rent',
            name: 'Rent',
            kind: ScheduleKind.expense,
            recurrence: Recurrence(
              frequency: Frequency.monthly,
              start: LocalDate(2026, 11, 6),
            ),
            amount: Money(50000, _aud),
            accountId: 'bank',
            categoryId: 'groceries',
          ),
        ),
      );
      expect(find.textContaining('Planned · 1 due by'), findsOneWidget);
      expect(find.text('Planned'), findsOneWidget);
    });
  });
}
