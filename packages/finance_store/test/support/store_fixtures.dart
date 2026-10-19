import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';

import 'memory_key_store.dart';

const aud = Currency.aud;

Money m(String text) => Money.parse(text, aud);

LocalDate d(String text) => LocalDate.parse(text);

/// A temporary directory deleted by [dispose].
class TempDir {
  TempDir() : dir = Directory.systemTemp.createTempSync('finance_store');
  final Directory dir;

  Directory sub(String name) => Directory('${dir.path}/$name');

  void dispose() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

Future<FinanceStore> newStore(
  Directory dir, {
  MemoryKeyStore? keys,
  String? workspaceId,
  String? deviceId,
  SyncMode syncMode = SyncMode.local,
}) => FinanceStore.create(
  dir,
  keyProtection: KeyProtection.platform(keys ?? MemoryKeyStore()),
  workspaceId: workspaceId,
  deviceId: deviceId,
  syncMode: syncMode,
);

/// Creates bank, card, groceries, dining and salary.
Future<void> seedChart(FinanceStore store) async {
  await store.createAccount(
    const Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
  );
  await store.createAccount(
    const Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
  );
  await store.createCategory(
    const Category(
      id: 'groceries',
      name: 'Groceries',
      kind: CategoryKind.expense,
    ),
  );
  await store.createCategory(
    const Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
  );
  await store.createCategory(
    const Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
  );
}

TransactionDraft expense(
  String amount, {
  String account = 'bank',
  String category = 'groceries',
  String date = '2026-07-01',
  String? payee,
  String? notes,
  Set<String> tags = const {},
  JournalStatus status = JournalStatus.posted,
  String? id,
}) => TransactionDraft(
  type: TransactionType.expense,
  accountId: account,
  amount: m(amount),
  effectiveDate: d(date),
  splits: [Split(category, m(amount))],
  payee: payee,
  notes: notes,
  tags: tags,
  status: status,
  id: id,
);
