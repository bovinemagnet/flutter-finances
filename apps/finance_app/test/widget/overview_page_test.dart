import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/theme.dart';
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

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async => dir = await Directory.systemTemp.createTemp('overview'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
    const aud = Currency.aud;
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
      const Account(
        id: 'card',
        name: 'Credit card',
        type: AccountType.creditCard,
      ),
    );
    await store.createCategory(
      const Category(
        id: 'groceries',
        name: 'Groceries',
        kind: CategoryKind.expense,
      ),
    );
    state = AppState(store, today: () => LocalDate(2026, 10, 20));
    await state.post(
      TransactionDraft(
        type: TransactionType.openingBalance,
        accountId: 'bank',
        amount: Money(250000, aud),
        effectiveDate: LocalDate(2026, 10, 1),
      ),
    );
    await state.post(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'card',
        amount: Money(6420, aud),
        effectiveDate: LocalDate(2026, 10, 18),
        payee: 'Fresh Grocer',
        splits: [Split('groceries', Money(6420, aud))],
      ),
    );
    await state.savePlan(
      BudgetPlan(
        id: 'plan',
        name: 'Household',
        mode: BudgetMode.categoryOnly,
        schedule: PeriodSchedule(
          cycle: PeriodCycle.month,
          anchor: LocalDate(2026, 10, 1),
          timezone: 'Australia/Brisbane',
        ),
        versions: [
          BudgetVersion(
            id: 'v1',
            effectiveFrom: LocalDate(2026, 10, 1),
            income: Money(500000, aud),
            allocations: [
              BudgetAllocation.category('groceries', Money(80000, aud)),
            ],
          ),
        ],
      ),
    );
  });

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: OverviewPage(onNavigate: (_) {}, onOpenEntries: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('phone layout leads with the available figure and tiles', (
    tester,
  ) async {
    await seed(tester);
    await pumpAt(tester, const Size(390, 2400));
    expect(find.text('AVAILABLE UNTIL PAYDAY'), findsOneWidget);
    expect(find.text('NET WORTH'), findsOneWidget);
    expect(find.text('BILLS BEFORE PAYDAY'), findsOneWidget);
    expect(
      find.bySemanticsLabel(r'$64.20 spent of a $800.00 budget'),
      findsOneWidget,
    );
    expect(find.text('Credit card'), findsOneWidget);
    expect(find.text(r'-$64.20'), findsOneWidget);
    expect(find.text('Spending this period'), findsNothing);
    expect(find.text('RECENT TRANSACTIONS'), findsNothing);

    await tester.tap(find.text('How this is worked out'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Budget limit:'), findsOneWidget);
  });

  testWidgets('wide layout adds the spending chart and recent entries', (
    tester,
  ) async {
    await seed(tester);
    await pumpAt(tester, const Size(1400, 1600));
    expect(find.text('SPENT THIS PERIOD'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Spending chart: \$64\.20 spent so far')),
      findsOneWidget,
    );
    expect(find.text('RECENT TRANSACTIONS'), findsOneWidget);
    expect(find.text('Fresh Grocer'), findsOneWidget);
    expect(find.text('AVAILABLE UNTIL PAYDAY'), findsOneWidget);
  });
}
