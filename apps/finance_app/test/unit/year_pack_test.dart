import 'dart:convert';
import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/year_pack.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);
const _aud = Currency.aud;

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late Directory out;
  late AppState state;
  final year = DateRange.financialYear(2025);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pack');
    out = await Directory.systemTemp.createTemp('pack-out');
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(
      const Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
    );
    await store.createCategory(
      const Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
    );
    state = AppState(store, today: () => LocalDate(2026, 11, 5));
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
    await out.delete(recursive: true);
  });

  Future<Journal> spend(
    LocalDate date, {
    String payee = 'Grocer',
    Set<String> tags = const {},
  }) => state.post(
    TransactionDraft(
      type: TransactionType.expense,
      accountId: 'bank',
      amount: Money(1500, _aud),
      effectiveDate: date,
      splits: [Split('food', Money(1500, _aud))],
      payee: payee,
      tags: tags,
    ),
  );

  CapturedFile photo() => CapturedFile(
    img.encodePng(img.Image(width: 400, height: 600)),
    source: CaptureSource.fileImport,
  );

  Future<Receipt> receipt({DateTime? capturedAt}) =>
      state.receipts.capture([photo()], capturedAt: capturedAt);

  List<String> manifestIds() {
    final manifest = jsonDecode(
      File('${out.path}/receipts/manifest.json').readAsStringSync(),
    ) as Map;
    return [
      for (final e in manifest['receipts'] as List) e['receiptId'] as String,
    ];
  }

  test('is named for its year', () {
    expect(yearPackName(year), 'finance-FY2025-26');
  });

  test(
    'holds the transactions, summary, receipts and an explanation',
    () async {
      await spend(LocalDate(2025, 10, 1));
      await writeYearPack(state, out, year);
      expect(File('${out.path}/transactions.csv').existsSync(), isTrue);
      expect(File('${out.path}/summary.csv').existsSync(), isTrue);
      expect(File('${out.path}/receipts/manifest.json').existsSync(), isTrue);
      expect(File('${out.path}/README.txt').existsSync(), isTrue);
    },
  );

  test('says it is a record and not tax advice', () async {
    await writeYearPack(state, out, year);
    final readme = File('${out.path}/README.txt').readAsStringSync();
    expect(readme, contains('not tax advice'));
    expect(readme, contains('1 July 2025'));
    expect(readme, contains('30 June 2026'));
  });

  test('has only that year\'s transactions, with their tags', () async {
    await spend(LocalDate(2025, 6, 30), payee: 'Before');
    await spend(LocalDate(2025, 7, 1), payee: 'First', tags: {'holiday'});
    await spend(LocalDate(2026, 6, 30), payee: 'Last');
    await spend(LocalDate(2026, 7, 1), payee: 'After');
    await writeYearPack(state, out, year);
    final csv = File('${out.path}/transactions.csv').readAsStringSync();
    expect(csv, contains('First'));
    expect(csv, contains('Last'));
    expect(csv, contains('holiday'));
    expect(csv, isNot(contains('Before')));
    expect(csv, isNot(contains('After')));
  });

  test('the summary agrees with the reports', () async {
    await spend(LocalDate(2025, 10, 1), tags: {'holiday'});
    await writeYearPack(state, out, year);
    expect(
      File('${out.path}/summary.csv').readAsStringSync(),
      yearSummaryCsv(state.ledger, year),
    );
  });

  group('receipts', () {
    test('a receipt linked to an entry in the year is included', () async {
      final r = await receipt(capturedAt: DateTime.utc(2024, 1, 1));
      final journal = await spend(LocalDate(2025, 10, 1));
      await state.receipts.review(
        r.id,
        ReceiptFields(
          merchant: 'Grocer',
          date: LocalDate(2025, 10, 1),
          total: Money(1500, _aud),
        ),
        AttachToTransaction(journal),
      );
      await writeYearPack(state, out, year);
      expect(manifestIds(), [r.id]);
    });

    test('a receipt linked to an entry in another year is left out', () async {
      final r = await receipt(capturedAt: DateTime.utc(2025, 10, 1));
      final journal = await spend(LocalDate(2024, 10, 1));
      await state.receipts.review(
        r.id,
        ReceiptFields(
          merchant: 'Grocer',
          date: LocalDate(2024, 10, 1),
          total: Money(1500, _aud),
        ),
        AttachToTransaction(journal),
      );
      await writeYearPack(state, out, year);
      expect(manifestIds(), isEmpty);
    });

    test('an unlinked receipt goes by when it was captured', () async {
      final inside = await receipt(capturedAt: DateTime.utc(2025, 10, 1));
      await receipt(capturedAt: DateTime.utc(2024, 10, 1));
      await writeYearPack(state, out, year);
      expect(manifestIds(), [inside.id]);
    });

    test('reports how many were copied', () async {
      await receipt(capturedAt: DateTime.utc(2025, 10, 1));
      await receipt(capturedAt: DateTime.utc(2024, 10, 1));
      final result = await writeYearPack(state, out, year);
      expect(result.receiptFiles, 1);
      expect(result.onServerOnly, 0);
      expect(
        Directory('${out.path}/receipts')
            .listSync()
            .whereType<File>()
            .where((f) => !f.path.endsWith('manifest.json')),
        hasLength(1),
      );
    });

    test('exporting everything still includes every receipt', () async {
      await receipt(capturedAt: DateTime.utc(2025, 10, 1));
      await receipt(capturedAt: DateTime.utc(2020, 1, 1));
      expect(
        await state.receipts.exportOriginals(Directory('${out.path}/all')),
        2,
      );
    });
  });

  test('writing a pack changes nothing in the workspace', () async {
    await spend(LocalDate(2025, 10, 1));
    final pending = state.unsyncedCount;
    await writeYearPack(state, out, year);
    expect(state.unsyncedCount, pending);
  });

  group('the years on offer', () {
    test('run from the earliest entry to now, newest first', () async {
      await spend(LocalDate(2024, 8, 1));
      expect(
        [for (final y in state.financialYears) y.label],
        ['FY2026-27', 'FY2025-26', 'FY2024-25'],
      );
    });

    test('are just this year with no entries', () {
      expect([for (final y in state.financialYears) y.label], ['FY2026-27']);
    });
  });
}
