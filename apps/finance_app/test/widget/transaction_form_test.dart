import 'package:finance_app/features/transactions/transaction_form.dart';
import 'package:finance_app/features/transactions/transaction_form_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  final chart = Chart(
    currency: Currency.aud,
    accounts: const [
      Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
      Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
    ],
    categories: const [
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
    ],
  );

  Future<List<TransactionDraft>> pumpForm(
    WidgetTester tester,
    TransactionFormModel model, {
    Size size = const Size(400, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saved = <TransactionDraft>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransactionForm(
            model: model,
            onSave: (d) async => saved.add(d),
          ),
        ),
      ),
    );
    return saved;
  }

  testWidgets('shows field errors and saves a valid expense', (tester) async {
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19));
    final saved = await pumpForm(tester, model);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Choose an account'), findsOneWidget);
    expect(saved, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '10+2.50');
    await tester.pump();
    expect(find.text(r'= $12.50'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Account'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Category'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saved.single.amount, Money(1250, Currency.aud));
    expect(saved.single.splits.single.categoryId, 'groceries');
  });

  testWidgets('split editor shows what is left to allocate', (tester) async {
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19))
      ..accountId = 'bank'
      ..amountText = '103.47'
      ..categoryId = 'groceries';
    await pumpForm(tester, model);
    await tester.tap(find.text('Split across categories'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount 1'),
      '80.00',
    );
    await tester.pump();
    expect(find.text(r'$23.47 left to allocate'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount 2'),
      '23.47',
    );
    await tester.pump();
    expect(find.text('Fully allocated'), findsOneWidget);
  });

  testWidgets('transfer explains card repayments', (tester) async {
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19));
    await pumpForm(tester, model);
    await tester.tap(find.text('Transfer'));
    await tester.pump();
    expect(find.text('To account'), findsOneWidget);
    expect(
      find.text('Paying a card or loan is a transfer, not spending'),
      findsOneWidget,
    );
    expect(find.text('Category'), findsNothing);
  });

  testWidgets('keypad builds an expression', (tester) async {
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19));
    await pumpForm(tester, model);
    await tester.tap(find.byTooltip('Open calculator keypad'));
    await tester.pumpAndSettle();
    for (final key in ['3', '×', '4', '.', '1', '0']) {
      await tester.tap(find.widgetWithText(OutlinedButton, key));
      await tester.pump();
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(model.amount, Money(1230, Currency.aud));
  });

  testWidgets('a refund links to the original purchase (FIN 06)', (tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = JournalFactory(chart).build(TransactionDraft(
      type: TransactionType.expense,
      accountId: 'card',
      amount: Money(10000, Currency.aud),
      effectiveDate: LocalDate(2026, 9, 20),
      payee: 'Outdoor Store',
      splits: [Split('groceries', Money(10000, Currency.aud))],
    ));
    final saved = <TransactionDraft>[];
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransactionForm(
          model: model,
          refundCandidates: [original],
          onSave: (d) async => saved.add(d),
        ),
      ),
    ));
    await tester.tap(find.text('Refund'));
    await tester.pump();
    await tester.tap(find.text('Refund of'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Outdoor Store').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '40');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saved.single.refundOf, original.id);
    expect(saved.single.accountId, 'card');
    expect(saved.single.splits.single.categoryId, 'groceries');
  });

  testWidgets('backgrounding the app hands unsaved input over (UX 02)', (tester) async {
    final interrupted = <TransactionFormModel>[];
    final model = TransactionFormModel(chart, today: LocalDate(2026, 10, 19));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransactionForm(
          model: model,
          onSave: (_) async {},
          onInterrupted: interrupted.add,
        ),
      ),
    ));
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '12.50');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(interrupted, isNotEmpty);
    expect(interrupted.first.toDraftJson()['amountText'], '12.50');
  });
}
