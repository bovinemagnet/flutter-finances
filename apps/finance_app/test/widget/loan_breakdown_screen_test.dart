import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/accounts/loan_breakdown_screen.dart';
import 'package:finance_app/screens/pages/accounts_page.dart';
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

  Money aud(int minor) => Money(minor, Currency.aud);

  /// A $20,000 car loan with a $500 repayment, $80 of interest and a $5 fee
  /// in October 2026.
  Future<void> createLoan(WidgetTester tester) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('loan');
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
      await store.createAccount(
        const Account(id: 'car', name: 'Car loan', type: AccountType.loan),
      );
      for (final (id, name) in [
        ('interest', 'Loan interest'),
        ('fees', 'Loan fees'),
      ]) {
        await store.createCategory(
          Category(id: id, name: name, kind: CategoryKind.expense),
        );
      }
      state = AppState(store, today: () => LocalDate(2026, 10, 20));
      await state.post(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'car',
          amount: aud(2000000),
          effectiveDate: LocalDate(2026, 10, 1),
        ),
      );
      await state.post(
        TransactionDraft(
          type: TransactionType.transfer,
          accountId: 'bank',
          counterAccountId: 'car',
          amount: aud(50000),
          effectiveDate: LocalDate(2026, 10, 10),
        ),
      );
      for (final (category, minor) in [('interest', 8000), ('fees', 500)]) {
        await state.post(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'car',
            amount: aud(minor),
            effectiveDate: LocalDate(2026, 10, 12),
            splits: [Split(category, aud(minor))],
          ),
        );
      }
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await state.store.close();
        await dir.delete(recursive: true);
      });
    });
  }

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(800, 1400),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String field, String name) async {
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, field),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(name).last);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('shows principal, interest and fees apart', (tester) async {
    await createLoan(tester);
    await tester.runAsync(
      () => state.saveLoanCategories(
        'car',
        interest: {'interest'},
        fees: {'fees'},
      ),
    );
    await pump(tester, const LoanBreakdownScreen(accountId: 'car'));
    expect(find.text('Car loan'), findsOneWidget);
    expect(find.text('Principal repaid'), findsOneWidget);
    expect(find.text(r'$500.00'), findsOneWidget);
    expect(find.text('Interest'), findsOneWidget);
    expect(find.text(r'$80.00'), findsOneWidget);
    expect(find.text('Fees'), findsOneWidget);
    expect(find.text(r'$5.00'), findsOneWidget);
    expect(find.text('Owed on 20 Oct 2026'), findsOneWidget);
    expect(find.text(r'$19,585.00'), findsOneWidget);
    expect(find.text('Other charges'), findsNothing);
  });

  testWidgets('charges are other charges until their categories are chosen', (
    tester,
  ) async {
    await createLoan(tester);
    await pump(tester, const LoanBreakdownScreen(accountId: 'car'));
    expect(find.text('Other charges'), findsOneWidget);
    expect(find.text(r'$85.00'), findsOneWidget);

    await choose(tester, 'Interest category', 'Loan interest');
    expect(find.text(r'$80.00'), findsOneWidget);
    expect(find.text(r'$5.00'), findsOneWidget);
    expect(state.loanCategories('car').interest, {'interest'});

    await choose(tester, 'Fees category', 'Loan fees');
    expect(find.text('Other charges'), findsNothing);
    expect(state.loanCategories('car').fees, {'fees'});
  });

  testWidgets('fits a small phone at 200% text', (tester) async {
    await createLoan(tester);
    await pump(
      tester,
      const LoanBreakdownScreen(accountId: 'car'),
      size: const Size(360, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.widgetWithText(DropdownButtonFormField<String>, 'Fees category'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a category chosen for interest is not offered for fees', (
    tester,
  ) async {
    await createLoan(tester);
    await pump(tester, const LoanBreakdownScreen(accountId: 'car'));
    await choose(tester, 'Interest category', 'Loan interest');
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Fees category'),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Scrollable).last,
        matching: find.text('Loan interest'),
      ),
      findsNothing,
    );
  });

  testWidgets('the accounts menu opens it for loans only', (tester) async {
    await createLoan(tester);
    await pump(tester, const AccountsPage());
    await tester.tap(find.byTooltip('Actions for Everyday'));
    await tester.pumpAndSettle();
    expect(find.text('Principal and interest'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions for Car loan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Principal and interest'));
    await tester.pumpAndSettle();
    expect(find.byType(LoanBreakdownScreen), findsOneWidget);
  });
}
