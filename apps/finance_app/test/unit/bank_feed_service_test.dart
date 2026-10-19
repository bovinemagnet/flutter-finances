import 'dart:convert';
import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/bank_feed_service.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

BankProposal _proposal({
  String recordId = 'r1',
  int amountMinor = -4250,
  bool pending = false,
  BankProposalKind kind = BankProposalKind.newTransaction,
  String? relatedRecordId,
  String? journalId,
  String proposalStatus = 'open',
}) => BankProposal(
  recordId: recordId,
  accountId: 'sb-everyday',
  pending: pending,
  amountMinor: amountMinor,
  currency: 'AUD',
  date: '2026-10-18',
  description: 'GROCER 123',
  kind: kind,
  proposalStatus: proposalStatus,
  relatedRecordId: relatedRecordId,
  journalId: journalId,
);

void main() {
  late Directory dir;
  late AppState state;
  late List<http.Request> requests;
  late BankFeedService service;
  var pushes = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bank_feed_test');
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => LocalDate(2026, 10, 19));
    await store.createAccount(
      const Account(
        id: 'bank',
        name: 'Everyday',
        type: AccountType.transaction,
      ),
    );
    await store.createCategory(
      const Category(
        id: 'groceries',
        name: 'Groceries',
        kind: CategoryKind.expense,
      ),
    );
    state.refresh();
    requests = [];
    pushes = 0;
    service = BankFeedService(
      state: state,
      client: BankFeedClient(
        SyncTransport(
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
          baseUri: Uri.parse('https://sync.test'),
        ),
      ),
      pushChanges: () async => pushes++,
    );
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  test('a proposal pre-fills a form the user reviews', () {
    final form = service.formFor(_proposal());
    expect(form.type, TransactionType.expense);
    expect(form.amountText, '42.50');
    expect(form.effectiveDate, LocalDate(2026, 10, 18));
    expect(form.payee, 'GROCER 123');
    expect(form.status, JournalStatus.posted);
    expect(
      service.formFor(_proposal(amountMinor: 900)).type,
      TransactionType.income,
    );
    expect(
      service.formFor(_proposal(pending: true)).status,
      JournalStatus.pending,
    );
  });

  test('accepting posts once, syncs, then records the journal', () async {
    final form = service.formFor(_proposal())
      ..accountId = 'bank'
      ..categoryId = 'groceries';
    await service.accept('c1', _proposal(), form.toDraft());
    final journalId = BankFeedService.journalIdFor('r1');
    expect(state.store.journal(journalId)?.status, JournalStatus.posted);
    expect(pushes, 1);
    expect(requests.single.url.path, '/v1/bank-feeds/c1/proposals/r1/decision');
    expect(jsonDecode(requests.single.body), {
      'decision': 'accepted',
      'journalId': journalId,
    });

    // A retry after a failed decision never posts a second entry.
    await service.accept('c1', _proposal(), form.toDraft());
    expect(
      state.ledger.journals.where((j) => j.payee == 'GROCER 123'),
      hasLength(1),
    );
    expect(service.enteredFrom(_proposal()), isNotNull);
  });

  test(
    'a posted transaction settles the pending entry already accepted',
    () async {
      final pendingForm = service.formFor(_proposal(pending: true))
        ..accountId = 'bank'
        ..categoryId = 'groceries';
      await service.accept(
        'c1',
        _proposal(pending: true),
        pendingForm.toDraft(),
      );
      final pendingId = BankFeedService.journalIdFor('r1');
      final pendingRecord = _proposal(
        pending: true,
        journalId: pendingId,
        proposalStatus: 'accepted',
      );
      final settling = _proposal(
        recordId: 'r2',
        amountMinor: -4300,
        kind: BankProposalKind.settlesPending,
        relatedRecordId: 'r1',
      );

      final pendingEntry = service.pendingEntryFor(settling, [
        pendingRecord,
        settling,
      ]);
      expect(pendingEntry?.id, pendingId);
      final form = service.formFor(settling, settling: pendingEntry);
      expect(form.amountText, '43.00');
      expect(form.status, JournalStatus.posted);
      await service.accept(
        'c1',
        settling,
        form.toDraft(),
        settling: pendingEntry,
      );

      final settled = state.store.journal(pendingId)!;
      expect(settled.status, JournalStatus.posted);
      expect(settled.amount, Money(4300, Currency.aud));
      expect(
        state.ledger.journals.where((j) => j.payee == 'GROCER 123'),
        hasLength(1),
        reason: 'the purchase is never entered twice',
      );
      expect(jsonDecode(requests.last.body)['journalId'], pendingId);
    },
  );

  test('finishing records an entry made earlier without posting', () async {
    final form = service.formFor(_proposal())
      ..accountId = 'bank'
      ..categoryId = 'groceries';
    await state.post(form.toDraft());
    await service.finish('c1', _proposal());
    expect(state.ledger.journals, hasLength(1));
    expect(pushes, 1);
    expect(
      jsonDecode(requests.single.body)['journalId'],
      BankFeedService.journalIdFor('r1'),
    );
  });

  test('dismissing records the decision and posts nothing', () async {
    await service.dismiss('c1', _proposal());
    expect(jsonDecode(requests.single.body), {'decision': 'dismissed'});
    expect(state.ledger.journals, isEmpty);
  });
}
