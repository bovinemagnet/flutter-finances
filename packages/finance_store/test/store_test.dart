import 'dart:convert';
import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/memory_key_store.dart';
import 'support/store_fixtures.dart';

void main() {
  late TempDir temp;
  late MemoryKeyStore keys;
  late FinanceStore store;

  setUp(() async {
    temp = TempDir();
    keys = MemoryKeyStore();
    store = await newStore(temp.sub('ws'), keys: keys);
    await seedChart(store);
  });

  tearDown(() async {
    await store.close();
    temp.dispose();
  });

  SyncCommand lastCommand() => store.pendingCommands().last.command;

  group('workspace', () {
    test('settings persist and reopen with the platform key', () async {
      final settings = store.settings;
      expect(settings.currency, aud);
      expect(settings.timezone, 'Australia/Sydney');
      expect(settings.locale, 'en_AU');
      expect(settings.syncMode, SyncMode.local);
      await store.close();
      store = await FinanceStore.open(
        temp.sub('ws'),
        keyProtection: KeyProtection.platform(keys),
      );
      expect(store.settings.workspaceId, settings.workspaceId);
      expect(store.settings.deviceId, settings.deviceId);
      expect(store.accounts().map((a) => a.id), containsAll(['bank', 'card']));
    });

    test('no plaintext key is written to the workspace', () async {
      final key = keys.entries.values.single;
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      for (final file in temp.sub('ws').listSync(recursive: true)) {
        if (file is! File) continue;
        final bytes = file.readAsBytesSync();
        expect(latin1.decode(bytes).contains(hex), isFalse);
        expect(latin1.decode(bytes).contains(latin1.decode(key)), isFalse);
      }
    });

    test('a password-protected workspace needs the right password', () async {
      final dir = temp.sub('pw');
      final pw = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('hunter2', kdf: testKdf),
      );
      await pw.close();
      await expectLater(
        FinanceStore.open(dir, keyProtection: KeyProtection.password('nope')),
        throwsA(isA<WrongPasswordException>()),
      );
      final reopened = await FinanceStore.open(
        dir,
        keyProtection: KeyProtection.password('hunter2'),
      );
      await reopened.close();
    });

    test('the password can be changed without re-encrypting', () async {
      final dir = temp.sub('pw2');
      final pw = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('old', kdf: testKdf),
      );
      await seedChart(pw);
      await pw.close();
      await FinanceStore.changeWorkspacePassword(dir, 'old', 'new');
      await expectLater(
        FinanceStore.open(dir, keyProtection: KeyProtection.password('old')),
        throwsA(isA<WrongPasswordException>()),
      );
      final reopened = await FinanceStore.open(
        dir,
        keyProtection: KeyProtection.password('new'),
      );
      expect(reopened.accounts(), hasLength(2));
      await reopened.close();
    });

    test('creating over an existing workspace is refused', () {
      expect(
        () => newStore(temp.sub('ws')),
        throwsA(isA<WorkspaceExistsException>()),
      );
    });
  });

  group('accounts and categories', () {
    test('creation records full entity.upsert commands', () {
      final commands = store.pendingCommands().map((e) => e.command).toList();
      expect(commands, hasLength(5));
      final bank = commands.first;
      expect(bank.type, CommandType.entityUpsert);
      expect(bank.entityType, 'account');
      expect(bank.baseRevision, 0);
      expect((bank.payload['fields'] as Map)['name'], 'Everyday');
      expect(bank.workspaceId, store.settings.workspaceId);
      expect(bank.deviceId, store.settings.deviceId);
    });

    test('updates send only the changed fields', () async {
      final bank = store.account('bank')!;
      await store.updateAccount(bank.copyWith(includeInForecast: false));
      expect(lastCommand().payload, {
        'fields': {'includeInForecast': false},
      });
      expect(store.account('bank')!.includeInForecast, isFalse);
    });

    test('marks pending entities as unsynced', () {
      expect(store.isUnsynced('account', 'bank'), isTrue);
      expect(
        store.unsyncedEntities(),
        contains(const EntityRef('category', 'groceries')),
      );
    });
  });

  group('transactions', () {
    test('posting saves journal, postings and command together', () async {
      final journal = await store.postTransaction(
        expense('63.25', payee: 'Corner Grocer'),
      );
      expect(store.journal(journal.id)!.amount, m('63.25'));
      final command = lastCommand();
      expect(command.type, CommandType.journalPost);
      expect(command.entityId, journal.id);
      expect((command.payload['journal'] as Map)['postings'], hasLength(2));
      expect(store.isUnsynced('journal', journal.id), isTrue);
      expect(store.displayBalance('bank'), m('-63.25'));
    });

    test('an invalid split writes nothing (A03)', () async {
      final before = store.pendingCommandCount;
      final draft = TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: m('103.47'),
        effectiveDate: d('2026-07-01'),
        splits: [Split('groceries', m('80.00')), Split('dining', m('23.46'))],
      );
      await expectLater(
        store.postTransaction(draft),
        throwsA(isA<DraftException>()),
      );
      expect(store.pendingCommandCount, before);
      expect(store.journals(), isEmpty);
    });

    test('a correction reverses and replaces the original', () async {
      final original = await store.postTransaction(expense('100.00'));
      final result = await store.correctTransaction(
        original.id,
        expense('120.00'),
      );
      expect(store.journal(original.id)!.status, JournalStatus.reversed);
      expect(store.journal(result.reversal.id)!.reversalOf, original.id);
      expect(store.journal(result.replacement!.id)!.replaces, original.id);
      expect(store.displayBalance('bank'), m('-120.00'));
      final command = lastCommand();
      expect(command.type, CommandType.journalCorrect);
      expect(command.entityId, original.id);
      expect(command.payload['originalId'], original.id);
      expect((command.payload['replacement'] as Map)['amountMinor'], 12000);
      expect(
        () => store.correctTransaction(original.id, expense('1.00')),
        throwsA(isA<StateError>()),
      );
    });

    test('posted journals cannot be replaced by posting again', () async {
      final original = await store.postTransaction(expense('10.00'));
      expect(
        () => store.postTransaction(expense('11.00', id: original.id)),
        throwsA(isA<ImmutableJournalException>()),
      );
    });

    test('drafts can be edited and deleted', () async {
      final draft = await store.postTransaction(
        expense('5.00', status: JournalStatus.draft),
      );
      expect(store.displayBalance('bank'), m('0.00'));
      await store.postTransaction(
        expense('6.00', status: JournalStatus.draft, id: draft.id),
      );
      expect(store.journal(draft.id)!.amount, m('6.00'));
      await store.deleteDraft(draft.id);
      expect(store.journal(draft.id), isNull);
      expect(lastCommand().type, CommandType.entityDelete);
      final posted = await store.postTransaction(expense('1.00'));
      expect(
        () => store.deleteDraft(posted.id),
        throwsA(isA<ImmutableJournalException>()),
      );
    });

    test('annotations change metadata without touching postings', () async {
      final j = await store.postTransaction(expense('9.00', payee: 'Cafe'));
      await store.annotateTransaction(
        j.id,
        notes: 'team lunch',
        tags: {'work'},
      );
      final view = store.journal(j.id)!;
      expect(view.notes, 'team lunch');
      expect(view.tags, {'work'});
      expect(view.postings, j.postings);
      expect(lastCommand().entityType, 'journalAnnotation');
      expect(store.searchTransactions('lunch').map((x) => x.id), [j.id]);
    });

    test('lists journals newest first with paging', () async {
      for (var i = 1; i <= 5; i++) {
        await store.postTransaction(expense('1.00', date: '2026-07-0$i'));
      }
      final page = store.journals(limit: 2, offset: 1);
      expect(page.map((j) => j.effectiveDate.toString()), [
        '2026-07-04',
        '2026-07-03',
      ]);
      expect(
        store.journals(from: d('2026-07-02'), to: d('2026-07-03')),
        hasLength(2),
      );
    });
  });

  group('SQL aggregation agrees with LedgerProjection', () {
    test('card purchase, repayment, refund and income', () async {
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: m('1000.00'),
          effectiveDate: d('2026-06-30'),
        ),
      );
      await store.postTransaction(expense('120.00', account: 'card'));
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.transfer,
          accountId: 'bank',
          counterAccountId: 'card',
          amount: m('120.00'),
          effectiveDate: d('2026-07-10'),
        ),
      );
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.income,
          accountId: 'bank',
          amount: m('2000.00'),
          effectiveDate: d('2026-07-15'),
          splits: [Split('salary', m('2000.00'))],
        ),
      );
      await store.postTransaction(expense('100.00', date: '2026-07-20'));
      await store.postTransaction(
        TransactionDraft(
          type: TransactionType.refund,
          accountId: 'bank',
          amount: m('40.00'),
          effectiveDate: d('2026-08-02'),
          splits: [Split('groceries', m('40.00'))],
        ),
      );
      await store.postTransaction(
        expense('7.00', status: JournalStatus.pending, date: '2026-07-21'),
      );
      final projection = store.projection();
      final from = d('2026-07-01');
      final to = d('2026-08-31');
      expect(store.expenses(from, to), projection.expenses(from, to));
      expect(store.expenses(from, to), m('180.00'));
      expect(store.income(from, to), projection.income(from, to));
      expect(store.netWorth(), projection.netWorth());
      for (final id in ['bank', 'card']) {
        expect(store.displayBalance(id), projection.displayBalance(id));
        expect(
          store.displayBalance(id, includePending: true),
          projection.displayBalance(id, includePending: true),
        );
      }
      expect(
        store.categoryNet('groceries', from, to),
        projection.categoryNet('groceries', from, to),
      );
      expect(store.displayBalances()['card'], m('0.00'));
      expect(
        store.displayBalance('bank', asOf: d('2026-07-10')),
        projection.displayBalance('bank', asOf: d('2026-07-10')),
      );
    });
  });

  group('generic entities', () {
    test('any entity type is stored with field-level commands', () async {
      await store.upsertEntity('budgetPlan', 'b1', {
        'id': 'b1',
        'name': 'July',
        'plannedMinor': 50000,
      });
      expect(lastCommand().payload['fields'], {
        'id': 'b1',
        'name': 'July',
        'plannedMinor': 50000,
      });
      await store.upsertEntity('budgetPlan', 'b1', {
        'id': 'b1',
        'name': 'July',
        'plannedMinor': 55000,
      });
      expect(lastCommand().payload, {
        'fields': {'plannedMinor': 55000},
      });
      expect(store.entity('budgetPlan', 'b1')!.json['plannedMinor'], 55000);
      await store.deleteEntity('budgetPlan', 'b1');
      expect(store.entity('budgetPlan', 'b1'), isNull);
      expect(store.entities('budgetPlan'), isEmpty);
      expect(store.entities('budgetPlan', includeDeleted: true), hasLength(1));
      expect(lastCommand().type, CommandType.entityDelete);
    });

    test('registered validators reject malformed JSON', () async {
      await store.close();
      store = await FinanceStore.open(
        temp.sub('ws'),
        keyProtection: KeyProtection.platform(keys),
        validators: {
          'goal': (json) {
            if (json['targetMinor'] is! int) {
              throw const FormatException('targetMinor must be an integer');
            }
          },
        },
      );
      final before = store.pendingCommandCount;
      await expectLater(
        store.upsertEntity('goal', 'g1', {'targetMinor': 1.5}),
        throwsA(isA<FormatException>()),
      );
      expect(store.pendingCommandCount, before);
    });

    test('receipt text is searchable without registration', () async {
      await store.upsertEntity('receipt', 'r1', {
        'merchant': 'Bunnings Warehouse',
        'extractedText': 'TIMBER 2.4M TOTAL 63.25',
      });
      expect(store.search('timber').map((h) => h.ref), [
        const EntityRef('receipt', 'r1'),
      ]);
      expect(store.search('bunn', entityTypes: {'journal'}), isEmpty);
    });
  });

  group('search', () {
    test('matches payee prefixes, amounts and dates', () async {
      final a = await store.postTransaction(
        expense('63.25', payee: 'Corner Grocer', date: '2026-07-03'),
      );
      final b = await store.postTransaction(
        expense('12.00', payee: 'Petrol Station', tags: {'car'}),
      );
      expect(store.searchTransactions('corn').map((j) => j.id), [a.id]);
      expect(store.searchTransactions('63.25').map((j) => j.id), [a.id]);
      expect(store.searchTransactions('2026-07-03').map((j) => j.id), [a.id]);
      expect(store.searchTransactions('car').map((j) => j.id), [b.id]);
      expect(store.searchTransactions('"); DROP TABLE'), isEmpty);
    });
  });

  group('undo (UX 02)', () {
    test('undoing a post removes the journal and its command', () async {
      final before = store.pendingCommandCount;
      final j = await store.postTransaction(expense('5.00'));
      expect(store.lastUndoableAction!.entity, EntityRef('journal', j.id));
      expect(await store.undoLastAction(), isTrue);
      expect(store.journal(j.id), isNull);
      expect(store.pendingCommandCount, before);
    });

    test('undoing a correction restores the original', () async {
      final j = await store.postTransaction(expense('5.00'));
      final c = await store.correctTransaction(j.id, expense('6.00'));
      await store.undoLastAction();
      expect(store.journal(j.id)!.status, JournalStatus.posted);
      expect(store.journal(c.reversal.id), isNull);
      expect(store.journal(c.replacement!.id), isNull);
      expect(store.displayBalance('bank'), m('-5.00'));
    });

    test('undoing an update restores the previous value', () async {
      final bank = store.account('bank')!;
      await store.updateAccount(bank.copyWith(name: 'Bills'));
      await store.undoLastAction();
      expect(store.account('bank')!.name, 'Everyday');
    });
  });

  test('saves survive reopening (acknowledged after commit)', () async {
    final j = await store.postTransaction(expense('42.00'));
    await store.close();
    store = await FinanceStore.open(
      temp.sub('ws'),
      keyProtection: KeyProtection.platform(keys),
    );
    expect(store.journal(j.id)!.amount, m('42.00'));
    expect(store.isUnsynced('journal', j.id), isTrue);
  });
}
