import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/pages/accounts_page.dart';
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

/// UX 03: what a bank reported stays distinct from what the app calculates.
/// Fails saving a reconciliation once, as a full disk would.
class _FailsOnceAppState extends AppState {
  _FailsOnceAppState(super.store, {required super.today});
  var _failed = false;

  @override
  Future<void> completeReconciliation(
    Account account, {
    required LocalDate date,
    required Money statement,
    TransactionDraft? adjustment,
  }) {
    if (!_failed) {
      _failed = true;
      throw const FileSystemException('disk full');
    }
    return super.completeReconciliation(
      account,
      date: date,
      statement: statement,
      adjustment: adjustment,
    );
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  const bank = Account(
    id: 'bank',
    name: 'Everyday',
    type: AccountType.transaction,
  );

  setUp(() async => dir = await Directory.systemTemp.createTemp('observed'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> start(WidgetTester tester) => tester.runAsync(() async {
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(bank);
    state = AppState(store, today: () => LocalDate(2026, 11, 4));
    await state.post(
      TransactionDraft(
        type: TransactionType.openingBalance,
        accountId: 'bank',
        amount: Money(100000, _aud),
        effectiveDate: LocalDate(2026, 11, 1),
      ),
    );
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(411, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Widget overview() => OverviewPage(onNavigate: (_) {}, onOpenEntries: (_) {});

  testWidgets('with no statement, no bank balance is claimed', (tester) async {
    await start(tester);
    await pumpPage(tester, overview());
    expect(find.textContaining('Bank balance'), findsNothing);
  });

  testWidgets('a saved statement shows beside the calculated balance', (
    tester,
  ) async {
    await start(tester);
    await tester.runAsync(
      () => state.saveBalanceObservation(
        'bank',
        date: LocalDate(2026, 10, 31),
        balance: Money(95000, _aud),
      ),
    );
    await pumpPage(tester, overview());
    expect(
      find.textContaining(r'Bank balance $950.00 on 31 Oct 2026'),
      findsOneWidget,
    );
    expect(find.text(r'$1,000.00'), findsWidgets);
  });

  testWidgets('a bank balance never changes the calculated one', (
    tester,
  ) async {
    await start(tester);
    await tester.runAsync(
      () => state.saveBalanceObservation(
        'bank',
        date: LocalDate(2026, 11, 2),
        balance: Money(1, _aud),
      ),
    );
    expect(state.ledger.displayBalance('bank'), Money(100000, _aud));
    expect(state.ledger.journals, hasLength(1));
  });

  testWidgets('an older statement does not replace a newer one', (
    tester,
  ) async {
    await start(tester);
    await tester.runAsync(() async {
      await state.saveBalanceObservation(
        'bank',
        date: LocalDate(2026, 11, 2),
        balance: Money(90000, _aud),
      );
      await state.saveBalanceObservation(
        'bank',
        date: LocalDate(2026, 10, 2),
        balance: Money(80000, _aud),
      );
    });
    final observed = state.balanceObservation('bank')!;
    expect(observed.date, LocalDate(2026, 11, 2));
    expect(observed.balance, Money(90000, _aud));
  });

  testWidgets('an amount owed is described as owed', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      await state.store.createAccount(
        const Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
      );
      state.refresh();
      await state.saveBalanceObservation(
        'card',
        date: LocalDate(2026, 11, 1),
        balance: Money(5000, _aud),
      );
    });
    await pumpPage(tester, overview());
    expect(
      find.textContaining(r'Bank says $50.00 owed on 1 Nov 2026'),
      findsOneWidget,
    );
  });

  testWidgets('a card in credit is not described as owing', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      await state.store.createAccount(
        const Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
      );
      state.refresh();
      await state.saveBalanceObservation(
        'card',
        date: LocalDate(2026, 11, 1),
        balance: Money(-5000, _aud),
      );
    });
    await pumpPage(tester, overview());
    expect(
      find.textContaining(r'Bank says $50.00 in credit on 1 Nov 2026'),
      findsOneWidget,
    );
    expect(find.textContaining('owed'), findsNothing);
  });

  group('when saving a reconciliation fails', () {
    Future<void> startFailing(WidgetTester tester) async {
      await tester.runAsync(() async {
        final store = await FinanceStore.create(
          dir,
          keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
        );
        await store.createAccount(bank);
        state = _FailsOnceAppState(store, today: () => LocalDate(2026, 11, 4));
        await state.post(
          TransactionDraft(
            type: TransactionType.openingBalance,
            accountId: 'bank',
            amount: Money(100000, _aud),
            effectiveDate: LocalDate(2026, 11, 1),
          ),
        );
      });
      await pumpPage(tester, ReconcileScreen(state: state, account: bank));
      await tester.enterText(find.byType(TextField).first, '1100');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish reconciliation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record adjustment'));
      await settle(tester);
    }

    testWidgets('it says so, and finishing again adjusts only once', (
      tester,
    ) async {
      await startFailing(tester);
      expect(find.byType(ReconcileScreen), findsOneWidget);
      expect(find.textContaining('could not be saved'), findsOneWidget);
      expect(state.ledger.journals, hasLength(1));

      await tester.tap(find.text('Finish reconciliation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record adjustment'));
      await settle(tester);
      expect(state.ledger.journals, hasLength(2));
      expect(state.ledger.displayBalance('bank'), Money(110000, _aud));
      expect(state.balanceObservation('bank')!.balance, Money(110000, _aud));
    });

    testWidgets('the message goes once the amount changes', (tester) async {
      await startFailing(tester);
      await tester.enterText(find.byType(TextField).first, '1000');
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be saved'), findsNothing);
    });
  });

  testWidgets('a rename during a reconciliation is not undone', (tester) async {
    await start(tester);
    await pumpPage(tester, ReconcileScreen(state: state, account: bank));
    await tester.runAsync(
      () => state.store.updateAccount(bank.copyWith(name: 'Bills')),
    );
    await tester.enterText(find.byType(TextField).first, '1000');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish reconciliation'));
    await settle(tester);
    final saved = state.store.account('bank')!;
    expect(saved.name, 'Bills');
    expect(saved.lastReconciledOn, LocalDate(2026, 11, 4));
  });

  group('the reconciled date', () {
    Future<void> reconcile(LocalDate date) => state.completeReconciliation(
      state.store.account('bank')!,
      date: date,
      statement: Money(100000, _aud),
    );

    testWidgets('does not move back for an older statement', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await reconcile(LocalDate(2026, 11, 2));
        await reconcile(LocalDate(2026, 10, 2));
      });
      expect(
        state.store.account('bank')!.lastReconciledOn,
        LocalDate(2026, 11, 2),
      );
    });

    testWidgets('can be corrected from one in the future', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await reconcile(LocalDate(2027, 11, 2));
        await reconcile(LocalDate(2026, 11, 2));
      });
      expect(
        state.store.account('bank')!.lastReconciledOn,
        LocalDate(2026, 11, 2),
      );
    });
  });

  testWidgets('a statement dated in the future can be corrected', (
    tester,
  ) async {
    await start(tester);
    await tester.runAsync(() async {
      await state.saveBalanceObservation(
        'bank',
        date: LocalDate(2027, 11, 1),
        balance: Money(90000, _aud),
      );
      await state.saveBalanceObservation(
        'bank',
        date: LocalDate(2026, 11, 1),
        balance: Money(80000, _aud),
      );
    });
    final observed = state.balanceObservation('bank')!;
    expect(observed.date, LocalDate(2026, 11, 1));
    expect(observed.balance, Money(80000, _aud));
  });

  testWidgets('finishing a reconciliation saves what the statement said', (
    tester,
  ) async {
    await start(tester);
    await pumpPage(tester, ReconcileScreen(state: state, account: bank));
    await tester.enterText(find.byType(TextField).first, '1000');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish reconciliation'));
    await settle(tester);
    final observed = state.balanceObservation('bank')!;
    expect(observed.balance, Money(100000, _aud));
    expect(observed.date, LocalDate(2026, 11, 4));
  });
}
