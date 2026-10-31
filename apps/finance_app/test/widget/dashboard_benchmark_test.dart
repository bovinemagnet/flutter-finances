// The benchmark reports its figures.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/theme.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/pages/overview_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:finance_app/data/entity_types.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

Duration p95(List<Duration> samples) {
  final sorted = [...samples]..sort();
  return sorted[(sorted.length * 0.95).ceil() - 1];
}

/// NFR 02 on the development host: the Overview with 100,000 posted
/// transactions. Reference devices are slower, so these are upper bounds to
/// keep, not proof of the phone targets.
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  final key = KeyProtection.password('secret', kdf: _fastKdf);
  final today = LocalDate(2026, 10, 20);

  setUp(() async => dir = await Directory.systemTemp.createTemp('dashboard'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> seed() async {
    const aud = Currency.aud;
    final store = await FinanceStore.create(dir, keyProtection: key);
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
    final random = Random(42);
    // Five years of history from 977 merchants. Names carry no digits,
    // which merchant normalisation drops (store numbers), so they stay
    // distinct.
    const first =
        'Acacia Banksia Coral Dune Ember Fern Grove Harbour Inlet '
        'Jarrah Kestrel Lagoon Mallee Nectar Opal Pelican Quartz Reef Saltbush '
        'Tide Uluru Vista Wattle Wren Yabby Zephyr Basalt Cedar Delta Estuary '
        'Flint';
    const second =
        'Bakery Books Butcher Cafe Chemist Cinema Deli Fuel Garden '
        'Grocer Hardware Kitchen Market Motors Music Optics Outdoors Pantry '
        'Pets Pharmacy Plumbing Produce Sports Stationery Supply Tavern Tools '
        'Toys Traders Vet Wine Works';
    final merchants = [
      for (final a in first.split(' '))
        for (final b in second.split(' ')) '$a $b',
    ];
    final start = DateTime.utc(2021, 11, 1);
    // Posting 100,000 entries one by one would take minutes; write them in
    // one transaction as the store's own benchmark does.
    // ignore: invalid_use_of_internal_member
    final ctx = store.context;
    ctx.write(() {
      for (var i = 0; i < 100000; i++) {
        final minor = 100 + random.nextInt(20000);
        final day = start.add(Duration(days: random.nextInt(1815)));
        final date =
            '${day.year}-${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}';
        final account = i.isEven ? 'bank' : 'card';
        final id = 'bench-$i';
        ctx.state.put(EntityRef(EntityTypes.journal, id), {
          'id': id,
          'type': 'expense',
          'status': 'posted',
          'effectiveDate': date,
          'enteredAt': '${date}T00:00:00.000Z',
          'currency': 'AUD',
          'postings': [
            {'account': 'groceries', 'amountMinor': minor},
            {'account': account, 'amountMinor': -minor},
          ],
          'accountId': account,
          'amountMinor': minor,
          'payee': merchants[i % 977],
        });
      }
    });
    await store.upsertEntity(
      AppEntityTypes.budgetPlan,
      'plan',
      budgetPlanToJson(
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
      ),
    );
    await store.close();
  }

  Widget overview() => AppScope(
    state: state,
    services: testServices(),
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: OverviewPage(onNavigate: (_) {}, onOpenEntries: (_) {}),
      ),
    ),
  );

  testWidgets('NFR 02: Overview at 100,000 transactions: cold under 3 s, '
      'warm p95 under 1 s', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(seed);

    final cold = Stopwatch()..start();
    await tester.runAsync(() async {
      final store = await FinanceStore.open(dir, keyProtection: key);
      state = AppState(store, today: () => today);
    });
    await tester.pumpWidget(overview());
    cold.stop();
    print(
      'NFR 02 cold open and first Overview frame: ${cold.elapsedMilliseconds} ms',
    );
    expect(find.text('NET WORTH'), findsOneWidget);
    expect(cold.elapsed, lessThan(const Duration(seconds: 3)));

    // Warm: back to the Overview from another page with nothing changed.
    final samples = <Duration>[];
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(const SizedBox());
      final warm = Stopwatch()..start();
      await tester.pumpWidget(overview());
      samples.add(warm.elapsed);
    }
    final result = p95(samples);
    print('NFR 02 warm Overview p95: ${result.inMilliseconds} ms');
    expect(result, lessThan(const Duration(seconds: 1)));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
