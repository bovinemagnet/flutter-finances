import 'package:finance_app/features/accounts/account_editor.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  Future<List<AccountEdit>> pump(
    WidgetTester tester, {
    Account? existing,
  }) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saved = <AccountEdit>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountEditor(
            currency: Currency.aud,
            today: LocalDate(2026, 10, 19),
            existing: existing,
            onSave: (edit) async => saved.add(edit),
          ),
        ),
      ),
    );
    return saved;
  }

  testWidgets('creates a card account with an amount owed as opening balance', (
    tester,
  ) async {
    final saved = await pump(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account name'),
      'Visa',
    );
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<AccountType>, 'Type'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Credit card').last);
    await tester.pumpAndSettle();
    expect(find.text('Amount owed'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount owed'),
      '250.00',
    );
    await tester.tap(find.text('Leave out of the cash forecast'));
    await tester.tap(find.text('Save account'));
    await tester.pump();

    final edit = saved.single;
    expect(edit.account.name, 'Visa');
    expect(edit.account.type, AccountType.creditCard);
    expect(edit.account.includeInForecast, isFalse);
    expect(edit.openingBalance, Money(25000, Currency.aud));
    expect(edit.openingBalanceDate, LocalDate(2026, 10, 19));
    final chart = Chart(
      currency: Currency.aud,
      accounts: [edit.account],
      categories: const [],
    );
    final journal = JournalFactory(chart).build(edit.openingBalanceDraft()!);
    expect(
      LedgerProjection(chart, [journal]).displayBalance(edit.account.id),
      Money(25000, Currency.aud),
    );
  });

  testWidgets('requires a name', (tester) async {
    final saved = await pump(tester);
    await tester.tap(find.text('Save account'));
    await tester.pump();
    expect(find.text('Give the account a name'), findsOneWidget);
    expect(saved, isEmpty);
  });

  testWidgets('editing keeps the type fixed and offers archiving', (
    tester,
  ) async {
    final saved = await pump(
      tester,
      existing: const Account(
        id: 'a1',
        name: 'Savings',
        type: AccountType.savings,
      ),
    );
    expect(find.text('Opening balance'), findsNothing);
    await tester.tap(find.text('Archive (keeps history)'));
    await tester.tap(find.text('Save account'));
    await tester.pump();
    expect(saved.single.account.id, 'a1');
    expect(saved.single.account.archived, isTrue);
    expect(saved.single.openingBalanceDraft(), isNull);
  });
}
