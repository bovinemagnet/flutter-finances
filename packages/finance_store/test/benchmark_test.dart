import 'dart:math';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/store_fixtures.dart';

Duration p95(List<Duration> samples) {
  final sorted = [...samples]..sort();
  return sorted[(sorted.length * 0.95).ceil() - 1];
}

void main() {
  late TempDir temp;
  late FinanceStore store;

  setUp(() async {
    temp = TempDir();
    store = await newStore(temp.sub('ws'));
    await seedChart(store);
  });

  tearDown(() async {
    await store.close();
    temp.dispose();
  });

  test('NFR 01: p95 of 200 durable saves is under 300 ms', () async {
    final samples = <Duration>[];
    for (var i = 0; i < 200; i++) {
      final sw = Stopwatch()..start();
      await store.postTransaction(
        expense('${i + 1}.25', payee: 'Shop $i', date: '2026-07-01'),
      );
      samples.add(sw.elapsed);
    }
    final result = p95(samples);
    printOnFailure('p95 save: ${result.inMicroseconds / 1000} ms');
    print('NFR 01 p95 save latency: ${result.inMicroseconds / 1000} ms');
    expect(result, lessThan(const Duration(milliseconds: 300)));
  });

  test('NFR 03 / NFR 09: p95 indexed search under 500 ms at 100,000 '
      'transactions', () async {
    final random = Random(42);
    const payees = [
      'Woolworths',
      'Coles',
      'Aldi',
      'Bunnings',
      'Shell',
      'Ampol',
      'Officeworks',
      'Chemist Warehouse',
      'JB Hi-Fi',
      'Kmart',
    ];
    final ctx = store.context;
    final insert = Stopwatch()..start();
    ctx.write(() {
      for (var i = 0; i < 100000; i++) {
        final minor = 100 + random.nextInt(50000);
        final day = 1 + random.nextInt(28);
        final month = 1 + random.nextInt(12);
        final id = 'bench-$i';
        ctx.state.put(EntityRef(EntityTypes.journal, id), {
          'id': id,
          'type': 'expense',
          'status': 'posted',
          'effectiveDate':
              '2025-${month.toString().padLeft(2, '0')}-'
              '${day.toString().padLeft(2, '0')}',
          'enteredAt': '2025-01-01T00:00:00.000Z',
          'currency': 'AUD',
          'postings': [
            {'account': 'groceries', 'amountMinor': minor},
            {'account': 'bank', 'amountMinor': -minor},
          ],
          'accountId': 'bank',
          'amountMinor': minor,
          'payee': '${payees[i % payees.length]} store ${i % 977}',
          'notes': i % 10 == 0 ? 'receipt kept for warranty $i' : null,
          'tags': i % 7 == 0 ? ['holiday'] : <String>[],
        });
      }
    });
    print('Inserted 100,000 journals in ${insert.elapsed.inSeconds} s');
    expect(store.journals(limit: 1, offset: 99999), hasLength(1));

    final queries = [
      'bunnings',
      'chem',
      'warranty',
      'holiday',
      'store 42',
      'officeworks 9',
      '63.25',
      '2025-03-14',
      'kmart',
      'shell',
    ];
    final samples = <Duration>[];
    for (var round = 0; round < 5; round++) {
      for (final q in queries) {
        final sw = Stopwatch()..start();
        store.searchTransactions(q);
        samples.add(sw.elapsed);
      }
    }
    final result = p95(samples);
    print('NFR 03 p95 search at 100k: ${result.inMicroseconds / 1000} ms');
    expect(result, lessThan(const Duration(milliseconds: 500)));
    expect(store.searchTransactions('bunnings'), hasLength(50));

    final sw = Stopwatch()..start();
    final balance = store.displayBalance('bank');
    final expenses = store.expenses(
      LocalDate(2025, 1, 1),
      LocalDate(2025, 12, 31),
    );
    print('SQL balance and period total: ${sw.elapsedMilliseconds} ms');
    expect(balance, -expenses);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
