import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/plan/debt_payoff_screen.dart';
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

  testWidgets('compares payoff approaches once terms are entered', (
    tester,
  ) async {
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('debt');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      await store.createAccount(
        const Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
      );
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'card',
          amount: Money(300000, Currency.aud),
          effectiveDate: LocalDate(2026, 10, 1),
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 10, 20));
    });
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: const MaterialApp(home: DebtPayoffScreen()),
      ),
    );
    expect(
      find.text('Add the interest rate and minimum payment'),
      findsOneWidget,
    );
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Interest rate per year'),
      '20.99',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Minimum monthly payment'),
      '90',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Highest interest first'), findsOneWidget);
    expect(find.text('Minimum payments only'), findsOneWidget);
    await tester.runAsync(() async {
      await state.store.close();
      await dir.delete(recursive: true);
    });
  });
}
