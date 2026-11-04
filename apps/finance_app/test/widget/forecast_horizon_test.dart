import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/shell.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/plan/forecast_view.dart';
import 'package:finance_app/screens/pages/plan_page.dart';
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

  setUp(() async => dir = await Directory.systemTemp.createTemp('horizon'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  /// A workspace with $1,000 and an annual bill of $1,200 due in September,
  /// which a 90 day forecast does not reach.
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(411, 1400),
    bool inShell = false,
  }) async {
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
          id: 'insurance',
          name: 'Insurance',
          kind: CategoryKind.expense,
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
      await state.post(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: Money(100000, _aud),
          effectiveDate: LocalDate(2026, 11, 1),
        ),
      );
      await state.saveSchedule(
        RecurringSchedule(
          id: 'cover',
          name: 'Car insurance',
          kind: ScheduleKind.expense,
          recurrence: Recurrence(
            frequency: Frequency.annually,
            start: LocalDate(2027, 9, 1),
          ),
          amount: Money(120000, _aud),
          accountId: 'bank',
          categoryId: 'insurance',
        ),
      );
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(
          home: inShell
              ? AdaptiveShell(
                  selected: Destination.plan,
                  onSelect: (_) {},
                  onAdd: (_) {},
                  body: const PlanPage(),
                )
              : const Scaffold(body: PlanPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forecast'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String horizon) async {
    await tester.tap(find.text(horizon));
    await tester.pumpAndSettle();
  }

  testWidgets('starts at 90 days, which the annual bill is beyond', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Cash forecast 4 Nov 2026 to 1 Feb 2027'), findsOneWidget);
    expect(find.textContaining('Lowest balance \$1,000.00'), findsOneWidget);
    expect(find.textContaining('less certain'), findsNothing);
  });

  testWidgets('12 months runs to the day before the same date next year', (
    tester,
  ) async {
    await pump(tester);
    await choose(tester, '12 months');
    expect(find.text('Cash forecast 4 Nov 2026 to 3 Nov 2027'), findsOneWidget);
  });

  testWidgets('12 months shows the annual bill and its effect', (tester) async {
    await pump(tester);
    await choose(tester, '12 months');
    expect(find.textContaining('Lowest balance -\$200.00'), findsOneWidget);
    expect(find.textContaining('On 1 Sept 2027'), findsOneWidget);
    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Car insurance'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ForecastView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Committed'), findsOneWidget);
  });

  testWidgets('6 months uses calendar months and stops before the bill', (
    tester,
  ) async {
    await pump(tester);
    await choose(tester, '6 months');
    expect(find.text('Cash forecast 4 Nov 2026 to 3 May 2027'), findsOneWidget);
    expect(find.textContaining('Lowest balance \$1,000.00'), findsOneWidget);
  });

  testWidgets('a longer horizon says it is less certain', (tester) async {
    await pump(tester);
    await choose(tester, '6 months');
    expect(find.textContaining('less certain'), findsOneWidget);
    await choose(tester, '90 days');
    expect(find.textContaining('less certain'), findsNothing);
  });

  testWidgets('on a phone the chart and table switch can be reached', (
    tester,
  ) async {
    await pump(tester, size: const Size(411, 760), inShell: true);
    await choose(tester, '12 months');
    final table = find.text('Table');
    bool clear() =>
        tester.widgetList(find.byType(FloatingActionButton)).isEmpty ||
        find
            .byType(FloatingActionButton)
            .evaluate()
            .every(
              (button) => !tester
                  .getRect(table)
                  .overlaps(tester.getRect(find.byWidget(button.widget))),
            );
    // Scrolls in small steps until the switch is clear of every floating
    // button, and fails if it leaves the screen first.
    for (var step = 0; step < 40 && !clear(); step++) {
      expect(table, findsOneWidget);
      await tester.dragFrom(const Offset(40, 400), const Offset(0, -60));
      await tester.pumpAndSettle();
    }
    expect(clear(), isTrue);
    await tester.tap(table);
    await tester.pumpAndSettle();
    final presentation = tester.widget<SegmentedButton<ForecastPresentation>>(
      find.byType(SegmentedButton<ForecastPresentation>),
    );
    expect(presentation.selected, {ForecastPresentation.table});
  });

  testWidgets('the horizon and what-if controls scroll with the forecast', (
    tester,
  ) async {
    await pump(tester, size: const Size(411, 760), inShell: true);
    final inForecast = find.descendant(
      of: find.byType(ForecastView),
      matching: find.text('12 months'),
    );
    expect(inForecast, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ForecastView),
        matching: find.text('What if…'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the month selector shows only where it does something', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byTooltip('Previous month'), findsNothing);

    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Previous month'), findsOneWidget);

    await tester.tap(find.text('Bills'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Previous month'), findsOneWidget);
  });
}
