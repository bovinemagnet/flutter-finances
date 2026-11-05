import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/memory_key_store.dart';
import 'support/store_fixtures.dart';

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

  TransactionDraft debt({
    String amount = '40.00',
    String? owedBy = 'Sam',
    JournalStatus status = JournalStatus.posted,
    String? id,
  }) => TransactionDraft(
    type: TransactionType.reimbursableExpense,
    accountId: 'bank',
    amount: m(amount),
    effectiveDate: d('2026-07-01'),
    payee: 'Concert',
    owedBy: owedBy,
    status: status,
    id: id,
  );

  test('is saved with the debt, and read back every way', () async {
    final saved = await store.postTransaction(debt());
    expect(saved.owedBy, 'Sam');
    expect(store.journal(saved.id)!.owedBy, 'Sam');
    expect(store.journals().single.owedBy, 'Sam');
    expect(store.projection().journals.single.owedBy, 'Sam');
    expect(owedToMe(store.projection()).items.single.journal.owedBy, 'Sam');
  });

  test('is saved in one action with the debt, so undo removes both', () async {
    final saved = await store.postTransaction(debt());
    expect(await store.undoLastAction(), isTrue);
    expect(store.journal(saved.id), isNull);
    expect(
      store
              .entity(journalAnnotationType, journalAnnotationId(saved.id))
              ?.deleted ??
          true,
      isTrue,
    );
  });

  test('undoing a correction brings the old debt and name back', () async {
    final saved = await store.postTransaction(debt());
    final result = await store.correctTransaction(
      saved.id,
      debt(amount: '50.00', owedBy: 'Alex'),
    );
    expect(store.lastUndoableAction!.type, CommandType.journalCorrect);
    expect(await store.undoLastAction(), isTrue);
    expect(store.journal(result.replacement!.id), isNull);
    final item = owedToMe(store.projection()).items.single;
    expect(item.journal.id, saved.id);
    expect(item.journal.owedBy, 'Sam');
    expect(item.outstanding, m('40.00'));
  });

  test('undoing the entry before a name never takes a later action', () async {
    final first = await store.postTransaction(debt(owedBy: null));
    final second = await store.postTransaction(debt());
    expect(await store.undoLastAction(), isTrue);
    expect(store.journal(second.id), isNull);
    expect(store.journal(first.id), isNotNull);
    expect(await store.undoLastAction(), isTrue);
    expect(store.journal(first.id), isNull);
  });

  test('cannot be undone once the entry itself has been sent', () async {
    final saved = await store.postTransaction(debt());
    final entries = store.pendingCommands().toList();
    store.context.outbox.recordAttempt([entries[entries.length - 2].seq]);
    expect(store.lastUndoableAction, isNull);
    expect(await store.undoLastAction(), isFalse);
    expect(store.journal(saved.id)!.owedBy, 'Sam');
  });

  test('changing only the name is undone on its own', () async {
    final saved = await store.postTransaction(debt());
    await store.setOwedBy(saved.id, 'Alex');
    expect(await store.undoLastAction(), isTrue);
    expect(store.journal(saved.id)!.owedBy, 'Sam');
  });

  test('never changes the journal command the server checks', () async {
    await store.postTransaction(debt());
    final commands = store.pendingCommands().map((e) => e.command).toList();
    final post = commands.singleWhere((c) => c.type == CommandType.journalPost);
    expect(post.payload.toString(), isNot(contains('Sam')));
    final note = commands.singleWhere(
      (c) => c.entityType == journalAnnotationType,
    );
    expect(note.payload.toString(), contains('Sam'));
  });

  test('a debt with no name writes no annotation', () async {
    await store.postTransaction(debt(owedBy: null));
    expect(
      store.pendingCommands().where(
        (e) => e.command.entityType == journalAnnotationType,
      ),
      isEmpty,
    );
  });

  test('stays with a corrected debt', () async {
    final saved = await store.postTransaction(debt());
    final result = await store.correctTransaction(
      saved.id,
      debt(amount: '50.00'),
    );
    expect(store.journal(result.replacement!.id)!.owedBy, 'Sam');
    final item = owedToMe(store.projection()).items.single;
    expect(item.journal.owedBy, 'Sam');
    expect(item.outstanding, m('50.00'));
  });

  test('can be taken off a draft when it is saved again', () async {
    final saved = await store.postTransaction(
      debt(status: JournalStatus.pending),
    );
    await store.postTransaction(
      debt(status: JournalStatus.pending, owedBy: null, id: saved.id),
    );
    expect(store.journal(saved.id)!.owedBy, isNull);
  });

  test('can be added or changed without touching the postings', () async {
    final saved = await store.postTransaction(debt(owedBy: null));
    final balance = store.displayBalance('bank');
    await store.setOwedBy(saved.id, 'Alex');
    final after = store.journal(saved.id)!;
    expect(after.owedBy, 'Alex');
    expect(after.postings, saved.postings);
    expect(store.displayBalance('bank'), balance);
  });

  test('can be taken off without touching the postings', () async {
    final saved = await store.postTransaction(debt());
    await store.setOwedBy(saved.id, null);
    expect(store.journal(saved.id)!.owedBy, isNull);
    expect(store.searchTransactions('Sam'), isEmpty);
  });

  test('cannot be set on an entry that does not exist', () {
    expect(
      store.setOwedBy('missing', 'Sam'),
      throwsA(isA<EntityNotFoundException>()),
    );
  });

  test('can be found by searching', () async {
    final saved = await store.postTransaction(debt());
    expect(store.searchTransactions('Sam').single.id, saved.id);
  });

  test('is still there after reopening', () async {
    final keys = MemoryKeyStore();
    final dir = temp.sub('again');
    final first = await newStore(dir, keys: keys);
    await seedChart(first);
    final saved = await first.postTransaction(debt());
    await first.close();
    final again = await FinanceStore.open(
      dir,
      keyProtection: KeyProtection.platform(keys),
    );
    addTearDown(again.close);
    expect(again.journal(saved.id)!.owedBy, 'Sam');
  });
}
