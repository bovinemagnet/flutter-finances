import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/editors.dart';
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

/// Exercises the entry editor as the app opens it, not just the form.
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async => dir = await Directory.systemTemp.createTemp('editor_flow'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester, {Journal? journal}) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      openTransactionEditor(context, journal: journal),
                  child: const Text('New'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('offers refund links and keeps interrupted entries', (
    tester,
  ) async {
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
          id: 'shopping',
          name: 'Shopping',
          kind: CategoryKind.expense,
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 10, 19));
      await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(10000, Currency.aud),
          effectiveDate: LocalDate(2026, 10, 1),
          payee: 'Outdoor Store',
          splits: [Split('shopping', Money(10000, Currency.aud))],
        ),
      );
    });
    await pumpHost(tester);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    expect(find.text('Refund of'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '12.50');
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(state.entryDraft?['amountText'], '12.50');
    for (final step in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(step);
    }

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(find.text('Continue your unsaved entry?'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Continue'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('12.50'), findsOneWidget);
  });

  group('after saving a change', () {
    late Journal journal;

    Future<void> saveAChange(WidgetTester tester) async {
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
            id: 'shopping',
            name: 'Shopping',
            kind: CategoryKind.expense,
          ),
        );
        state = AppState(store, today: () => LocalDate(2026, 10, 19));
        journal = await state.post(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: Money(10000, Currency.aud),
            effectiveDate: LocalDate(2026, 10, 1),
            splits: [Split('shopping', Money(10000, Currency.aud))],
          ),
        );
      });
      await pumpHost(tester, journal: journal);
      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Amount'), '12.50');
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Saved on this device'), findsOneWidget);
    }

    testWidgets('the offer to undo goes away by itself', (tester) async {
      await saveAChange(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('Undo reverses the change it was shown for', (tester) async {
      await saveAChange(tester);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(state.store.journal(journal.id)!.status, JournalStatus.posted);
      expect(find.text('This can no longer be undone'), findsNothing);
    });

    testWidgets('Undo says so when a later change has come first', (
      tester,
    ) async {
      await saveAChange(tester);
      final head = state.store.journals().last;
      await state.markReviewed([head.id]);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('This can no longer be undone'), findsOneWidget);
      expect(state.reviewedJournalIds, contains(head.id));
      expect(state.store.journal(journal.id)!.status, JournalStatus.reversed);
    });
  });
}
