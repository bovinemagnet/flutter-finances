import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/accounts/holdings_screen.dart';
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

  testWidgets('values holdings and applies the update after confirmation', (
    tester,
  ) async {
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('holdings');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      await store.createAccount(
        const Account(
          id: 'shares',
          name: 'Shares',
          type: AccountType.investment,
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
        child: const MaterialApp(home: HoldingsScreen(accountId: 'shares')),
      ),
    );

    Future<void> save() async {
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Add holding'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Code'), 'vas');
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Australian shares',
    );
    await save();
    expect(find.textContaining('VAS · Australian shares'), findsOneWidget);

    await tester.tap(find.byTooltip('Actions for VAS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record units bought'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Units'), '100');
    await save();

    await tester.tap(find.byTooltip('Actions for VAS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record a price'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Price per unit'),
      '120',
    );
    await save();
    expect(find.text(r'Value $12,000.00'), findsOneWidget);

    await tester.tap(find.text('Update value'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Update'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(state.ledger.displayBalance('shares'), Money(1200000, Currency.aud));
    await tester.runAsync(() async {
      await state.store.close();
      await dir.delete(recursive: true);
    });
  });
}
