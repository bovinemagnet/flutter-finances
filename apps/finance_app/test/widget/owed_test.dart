import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/accounts/owed_screen.dart';
import 'package:finance_app/features/transactions/transaction_form.dart';
import 'package:finance_app/features/transactions/transaction_form_model.dart';
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

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  var started = false;
  final today = LocalDate(2026, 7, 15);

  setUp(() async => dir = await Directory.systemTemp.createTemp('owed'));
  tearDown(() async {
    if (started) await state.store.close();
    started = false;
    await dir.delete(recursive: true);
  });

  Future<void> start(WidgetTester tester) => tester.runAsync(() async {
    started = true;
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(
      const Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
    );
    await store.createAccount(
      const Account(id: 'save', name: 'Savings', type: AccountType.savings),
    );
    await store.createCategory(
      const Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
    );
    state = AppState(store, today: () => today);
  });

  Future<Journal> paidFor(int minor, {String payee = 'Concert tickets'}) =>
      state.post(
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          accountId: 'bank',
          amount: Money(minor, _aud),
          effectiveDate: LocalDate(2026, 7, 1),
          payee: payee,
        ),
      );

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(411, 1600);
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
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  group('entering one', () {
    TransactionFormModel model() => TransactionFormModel(
      Chart(
        currency: _aud,
        accounts: const [
          Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
        ],
        categories: const [
          Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
        ],
      ),
      today: today,
    );

    test('needs no category, and is not an ordinary expense', () {
      final m = model()
        ..accountId = 'bank'
        ..amountText = '40'
        ..paidForSomeone = true;
      expect(m.needsCategory, isFalse);
      expect(m.errors, isEmpty);
      final draft = m.toDraft();
      expect(draft.type, TransactionType.reimbursableExpense);
      expect(draft.splits, isEmpty);
    });

    test('an ordinary expense still needs its category', () {
      final m = model()
        ..accountId = 'bank'
        ..amountText = '40';
      expect(m.errors, contains(EntryField.category));
      expect(m.paidForSomeone, isFalse);
    });

    test('only applies to an expense', () {
      final m = model()
        ..type = TransactionType.income
        ..paidForSomeone = true;
      expect(m.needsCategory, isTrue);
    });

    test('is remembered in a saved draft', () {
      final m = model()..paidForSomeone = true;
      final back = TransactionFormModel.fromDraftJson(
        m.chart,
        m.toDraftJson(),
        today: today,
      );
      expect(back.paidForSomeone, isTrue);
    });

    test('opens as itself when edited', () {
      final m = model();
      final journal = JournalFactory(m.chart).build(
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          accountId: 'bank',
          amount: Money(4000, _aud),
          effectiveDate: today,
        ),
      );
      final edit = TransactionFormModel.fromJournal(
        m.chart,
        journal,
        today: today,
      );
      expect(edit.paidForSomeone, isTrue);
      expect(edit.type, TransactionType.expense);
      expect(edit.toDraft().type, TransactionType.reimbursableExpense);
    });

    testWidgets('the switch hides the category and explains', (tester) async {
      tester.view.physicalSize = const Size(411, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = model();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionForm(model: m, onSave: (_) async {}),
          ),
        ),
      );
      expect(find.text('Category'), findsOneWidget);
      await tester.tap(find.text('Someone will pay me back'));
      await tester.pumpAndSettle();
      expect(m.paidForSomeone, isTrue);
      expect(find.text('Category'), findsNothing);
      expect(find.textContaining('not count as your spending'), findsOneWidget);
    });

    testWidgets('the switch is not offered for income', (tester) async {
      tester.view.physicalSize = const Size(411, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionForm(
              model: model()..type = TransactionType.income,
              onSave: (_) async {},
            ),
          ),
        ),
      );
      expect(find.text('Someone will pay me back'), findsNothing);
    });
  });

  group('the screen', () {
    testWidgets('explains itself when nothing is owed', (tester) async {
      await start(tester);
      await pumpPage(tester, const OwedScreen());
      expect(find.textContaining('Nobody owes you'), findsOneWidget);
    });

    testWidgets('shows each debt and the total', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await paidFor(4000);
        await paidFor(1000, payee: 'Dinner');
      });
      await pumpPage(tester, const OwedScreen());
      expect(find.text('Concert tickets'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.textContaining(r'$50.00'), findsOneWidget);
    });

    Future<void> openRepayment(WidgetTester tester, String payee) async {
      await tester.tap(find.text(payee));
      await tester.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Record repayment'));
      await settle(tester);
    }

    testWidgets('offers the full amount, and clears the debt', (tester) async {
      await start(tester);
      await tester.runAsync(() => paidFor(4000));
      await pumpPage(tester, const OwedScreen());
      final before = state.ledger.displayBalance('bank');
      await openRepayment(tester, 'Concert tickets');
      expect(find.widgetWithText(TextField, '40.00'), findsOneWidget);
      await confirm(tester);
      expect(state.owed.items, isEmpty);
      expect(state.owed.total, Money.zero(_aud));
      expect(state.ledger.displayBalance('bank'), before + Money(4000, _aud));
      expect(find.textContaining('Nobody owes you'), findsOneWidget);
    });

    testWidgets('takes part of it, leaving the rest', (tester) async {
      await start(tester);
      await tester.runAsync(() => paidFor(4000));
      await pumpPage(tester, const OwedScreen());
      await openRepayment(tester, 'Concert tickets');
      await tester.enterText(find.widgetWithText(TextField, '40.00'), '15');
      await tester.pumpAndSettle();
      await confirm(tester);
      final item = state.owed.items.single;
      expect(item.repaid, Money(1500, _aud));
      expect(item.outstanding, Money(2500, _aud));
      expect(find.textContaining(r'$15.00 repaid'), findsOneWidget);
    });

    testWidgets('can go into another account', (tester) async {
      await start(tester);
      await tester.runAsync(() => paidFor(4000));
      await pumpPage(tester, const OwedScreen());
      await openRepayment(tester, 'Concert tickets');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Savings').last);
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(state.ledger.displayBalance('save'), Money(4000, _aud));
    });

    for (final (text, why) in [
      ('50', 'more than is owed'),
      ('abc', 'an amount'),
      ('0', 'an amount'),
    ]) {
      testWidgets('refuses "$text"', (tester) async {
        await start(tester);
        await tester.runAsync(() => paidFor(4000));
        await pumpPage(tester, const OwedScreen());
        await openRepayment(tester, 'Concert tickets');
        await tester.enterText(find.widgetWithText(TextField, '40.00'), text);
        await tester.pumpAndSettle();
        expect(find.textContaining(why), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Record repayment'),
              )
              .onPressed,
          isNull,
        );
      });
    }

    testWidgets('never records anything by itself', (tester) async {
      await start(tester);
      await tester.runAsync(() => paidFor(4000));
      final count = state.ledger.journals.length;
      await pumpPage(tester, const OwedScreen());
      await openRepayment(tester, 'Concert tickets');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.ledger.journals, hasLength(count));
    });

    testWidgets('says when money came back with no debt to match', (
      tester,
    ) async {
      await start(tester);
      await tester.runAsync(() async {
        await paidFor(4000);
        await state.post(
          TransactionDraft(
            type: TransactionType.reimbursement,
            accountId: 'bank',
            amount: Money(1000, _aud),
            effectiveDate: today,
          ),
        );
      });
      await pumpPage(tester, const OwedScreen());
      expect(find.textContaining(r'$10.00 received'), findsOneWidget);
    });
  });

  group('the overview', () {
    Widget overview() =>
        OverviewPage(onNavigate: (_) {}, onOpenEntries: (_) {});

    testWidgets('says nothing when nothing is owed', (tester) async {
      await start(tester);
      await pumpPage(tester, overview());
      expect(find.textContaining('Owed to you'), findsNothing);
    });

    testWidgets('shows what is owed, and opens the list', (tester) async {
      await start(tester);
      await tester.runAsync(() => paidFor(4000));
      await pumpPage(tester, overview());
      expect(find.textContaining(r'Owed to you $40.00'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('Owed to you'));
      await tester.tap(find.textContaining('Owed to you'));
      await tester.pumpAndSettle();
      expect(find.byType(OwedScreen), findsOneWidget);
    });
  });
}
