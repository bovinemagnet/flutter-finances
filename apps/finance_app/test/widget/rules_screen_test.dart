import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/settings/rules_screen.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  late Directory dir;
  late AppState state;

  setUp(
    () async => dir = await Directory.systemTemp.createTemp('rules_screen'),
  );
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  TransactionDraft cafe(String category) => TransactionDraft(
    type: TransactionType.expense,
    accountId: 'bank',
    amount: Money(900, Currency.aud),
    effectiveDate: LocalDate(2026, 10, 1),
    payee: 'Corner Cafe',
    splits: [Split(category, Money(900, Currency.aud))],
  );

  Future<void> settleWrites(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Future<void> Function() prepare,
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
      for (final name in ['shopping', 'dining', 'groceries']) {
        await store.createCategory(
          Category(id: name, name: name, kind: CategoryKind.expense),
        );
      }
      state = AppState(store, today: () => LocalDate(2026, 10, 19));
      await prepare();
    });
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: const MaterialApp(home: RulesScreen()),
      ),
    );
  }

  /// Applies a rule through the screen, leaving its Undo on offer.
  Future<void> applyRule(WidgetTester tester) async {
    await pumpScreen(tester, () async {
      await state.post(cafe('shopping'));
      await state.saveRule(
        CategorisationRule(
          id: 'r1',
          name: 'Cafes',
          categoryId: 'dining',
          merchant: 'corner cafe',
        ),
      );
    });
    await tester.tap(find.text('Apply to existing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await settleWrites(tester);
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
  }

  testWidgets('says when an entry that has changed was left as it is', (
    tester,
  ) async {
    await applyRule(tester);
    await tester.runAsync(() async {
      final current = state.ledger.journals.singleWhere(
        (j) =>
            j.type == TransactionType.expense &&
            j.status == JournalStatus.posted,
      );
      await state.correct(current.id, cafe('groceries'));
    });
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Undo'));
    await settleWrites(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('1 of 1 entry had changed, so it was left as it is'),
      findsOneWidget,
    );
  });

  testWidgets('says nothing extra when everything was undone', (tester) async {
    await applyRule(tester);

    await tester.tap(find.text('Undo'));
    await settleWrites(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('left as'), findsNothing);
    expect(
      state.ledger.categoryNet(
        'shopping',
        LocalDate(2026, 10, 1),
        LocalDate(2026, 10, 19),
      ),
      Money(900, Currency.aud),
    );
  });

  group('the message about entries left as they are', () {
    test('matches how many there were', () {
      expect(
        rulesLeftAloneMessage(1, 3),
        '1 of 3 entries had changed, so it was left as it is',
      );
      expect(
        rulesLeftAloneMessage(2, 3),
        '2 of 3 entries had changed, so they were left as they are',
      );
      expect(
        rulesLeftAloneMessage(1, 1),
        '1 of 1 entry had changed, so it was left as it is',
      );
    });
  });

  group('adding a rule', () {
    Future<void> openNewRule(WidgetTester tester) async {
      await pumpScreen(tester, () async {});
      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
    }

    Future<void> chooseCategory(WidgetTester tester) async {
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dining').last);
      await tester.pumpAndSettle();
    }

    Future<void> enterMerchant(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }

    bool canSave(WidgetTester tester) =>
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed !=
        null;

    testWidgets('needs a merchant as well as a category', (tester) async {
      await openNewRule(tester);
      await chooseCategory(tester);
      expect(canSave(tester), isFalse);
    });

    testWidgets('needs a category as well as a merchant', (tester) async {
      await openNewRule(tester);
      await enterMerchant(tester, 'Corner Cafe');
      expect(canSave(tester), isFalse);
    });

    testWidgets('needs a merchant with a word a rule can match', (
      tester,
    ) async {
      await openNewRule(tester);
      await chooseCategory(tester);
      await enterMerchant(tester, '   ');
      expect(canSave(tester), isFalse);
      await enterMerchant(tester, '***');
      expect(canSave(tester), isFalse);
    });

    testWidgets('can be saved once both are filled in, in either order', (
      tester,
    ) async {
      await openNewRule(tester);
      await chooseCategory(tester);
      await enterMerchant(tester, 'Corner Cafe');
      expect(canSave(tester), isTrue);

      await tester.tap(find.text('Save'));
      await settleWrites(tester);
      await tester.pumpAndSettle();
      expect(state.rules.single.merchant, 'Corner Cafe');
      expect(state.rules.single.categoryId, 'dining');

      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      await enterMerchant(tester, 'Station Kiosk');
      await chooseCategory(tester);
      expect(canSave(tester), isTrue);
    });
  });
}
