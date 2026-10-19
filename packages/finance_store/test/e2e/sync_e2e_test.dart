@Tags(['e2e'])
library;

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';
import 'support/e2e.dart';

/// The sync client against the real server (`tool/e2e/run.sh`). Every
/// scenario uses its own users and workspace.
void main() {
  late TempDir temp;
  final open = <E2eDevice>[];

  setUp(() => temp = TempDir());

  tearDown(() async {
    for (final device in open) {
      await device.close();
    }
    open.clear();
    temp.dispose();
  });

  Future<E2eDevice> device(String name, String user) async {
    final created = await E2eDevice.create(temp, name, user: user);
    open.add(created);
    return created;
  }

  /// A creates a workspace with the chart and syncs it; B joins.
  Future<
    ({E2eDevice a, E2eDevice b, RemoteWorkspace workspace, TestChart chart})
  >
  twoDevices() async {
    final user = newUser('owner');
    final a = await device('a', user);
    final b = await device('b', user);
    final chart = TestChart();
    await chart.seed(a.store);
    final workspace = await a.client.createRemoteWorkspace(name: 'Household');
    await a.join(workspace);
    await b.join(workspace);
    return (a: a, b: b, workspace: workspace, chart: chart);
  }

  Future<String> saveReceipt(E2eDevice d, {int size = 4000}) async {
    final receiptId = newId();
    await d.store.upsertEntity('receipt', receiptId, {
      'id': receiptId,
      'merchant': 'Corner Grocer',
    });
    final asset = await d.store.vault.saveAsset(
      ownerType: 'receipt',
      ownerId: receiptId,
      kind: VaultAssetKind.source,
      contentType: 'image/jpeg',
      bytes: jpegBytes(size),
    );
    return asset.id;
  }

  Matcher httpError(int status, String code) => isA<SyncHttpException>()
      .having((e) => e.statusCode, 'statusCode', status)
      .having((e) => e.errorCode, 'errorCode', code);

  e2eTest('a workspace is created and two devices register', () async {
    final user = newUser('owner');
    final a = await device('a', user);
    final b = await device('b', user);
    final workspace = await a.client.createRemoteWorkspace(name: 'Household');
    expect(workspace.currencyCode, 'AUD');
    expect(workspace.timezone, 'Australia/Sydney');
    expect(await b.client.listRemoteWorkspaces(), [workspace]);
    for (final d in [a, b, a]) {
      await d.register(workspace);
    }
    await expectLater(
      b.client.previewBootstrap(remoteWorkspaceId: newId()),
      throwsA(httpError(403, 'DEVICE_NOT_AUTHORISED')),
    );
    final preview = await b.client.previewBootstrap(
      remoteWorkspaceId: workspace.id,
    );
    expect(preview.action, BootstrapAction.startEmpty);

    final stranger = await device('stranger', newUser('stranger'));
    expect(await stranger.client.listRemoteWorkspaces(), isEmpty);
    await expectLater(
      stranger.register(workspace),
      throwsA(httpError(404, 'WORKSPACE_NOT_FOUND')),
    );
  });

  e2eTest('offline history uploads and a second device receives identical '
      'balances', () async {
    final user = newUser('owner');
    final a = await device('a', user);
    final chart = TestChart();
    await chart.seed(a.store);
    await a.store.postTransaction(chart.income('2500.00'));
    await a.store.postTransaction(chart.expense('63.25', payee: 'Grocer'));
    await a.store.postTransaction(
      chart.expense('40.10', category: chart.dining, date: '2026-07-03'),
    );
    final lunch = await a.store.postTransaction(
      chart.expense('18.00', category: chart.dining, date: '2026-07-04'),
    );
    await a.store.correctTransaction(
      lunch.id,
      chart.expense('21.50', category: chart.dining, date: '2026-07-04'),
    );

    final workspace = await a.client.createRemoteWorkspace(name: 'Household');
    await a.register(workspace);
    final preview = await a.client.previewBootstrap(
      remoteWorkspaceId: workspace.id,
    );
    expect(preview.action, BootstrapAction.uploadLocal);
    await a.client.enableSync(preview);
    final upload = await a.sync();
    expect(upload.push.sent, preview.pendingCommands);
    expect(upload.push.accepted, preview.pendingCommands);
    expect(a.store.pendingCommandCount, 0);

    final b = await device('b', user);
    await b.register(workspace);
    final join = await b.client.previewBootstrap(
      remoteWorkspaceId: workspace.id,
    );
    expect(join.action, BootstrapAction.downloadRemote);
    await b.client.enableSync(join);
    await b.sync();

    expect(b.store.displayBalances(), a.store.displayBalances());
    expect(b.store.displayBalance(chart.bank), m('2375.15'));
    expect(b.store.netWorth(), a.store.netWorth());
    final july = (d('2026-07-01'), d('2026-07-31'));
    expect(b.store.expenses(july.$1, july.$2), m('124.85'));
    expect(b.store.income(july.$1, july.$2), m('2500.00'));
    expect(
      b.store.journals().map((j) => j.id).toSet(),
      a.store.journals().map((j) => j.id).toSet(),
    );
  });

  e2eTest('A09: a command batch sent twice applies once', () async {
    final s = await twoDevices();
    await s.a.store.postTransaction(s.chart.expense('20.00'));
    final batch = {
      'commands': [
        for (final e in s.a.store.pendingCommands()) e.command.toJson(),
      ],
    };
    final first = await s.a.client.transport.postJson(
      '/v1/sync/commands',
      batch,
    );
    final second = await s.a.client.transport.postJson(
      '/v1/sync/commands',
      batch,
    );
    final r1 = (first['results'] as List).single as Map;
    final r2 = (second['results'] as List).single as Map;
    expect(r1['status'], 'applied');
    expect(r2['status'], 'previously_applied');
    expect(r2['revision'], r1['revision']);
    expect(r2['cursor'], r1['cursor']);

    // The device's own retry of the same outbox entry is also harmless.
    final report = await s.a.sync();
    expect(report.push.accepted, 1);
    await s.b.sync();
    expect(s.b.store.displayBalance(s.chart.bank), m('-20.00'));
    expect(s.b.store.journals(), hasLength(1));
  });

  e2eTest('A10: concurrent amount corrections give one applied, one conflict '
      'and a single balanced resolution', () async {
    final s = await twoDevices();
    final original = await s.a.store.postTransaction(s.chart.expense('100.00'));
    await s.a.sync();
    await s.b.sync();

    await s.a.store.correctTransaction(original.id, s.chart.expense('120.00'));
    await s.b.store.correctTransaction(original.id, s.chart.expense('130.00'));
    expect((await s.a.sync()).push.accepted, 1);
    final report = await s.b.sync();
    expect(report.push.conflicts, 1);
    final review = s.b.store.openReviewItems().single;
    expect(review.kind, ReviewKind.conflict);
    expect(review.entity, EntityRef('journal', original.id));
    expect(review.serverState!['status'], 'reversed');
    expect(s.b.store.displayBalance(s.chart.bank), m('-120.00'));

    await s.b.store.resolveKeepLocal(review.id);
    expect((await s.b.sync()).push.accepted, 1);
    await s.a.sync();
    for (final device in [s.a, s.b]) {
      expect(device.store.displayBalance(s.chart.bank), m('-130.00'));
      expect(
        device.store.expenses(d('2026-07-01'), d('2026-07-31')),
        m('130.00'),
      );
      final journals = device.store.journals();
      for (final j in journals) {
        expect(j.postings.fold<int>(0, (t, p) => t + p.amount.minor), 0);
      }
      final inForce = journals.where(
        (j) =>
            j.status == JournalStatus.posted &&
            j.type == TransactionType.expense,
      );
      expect(inForce.single.amount, m('130.00'));
    }
  });

  e2eTest('metadata merges field by field; the same field conflicts', () async {
    final s = await twoDevices();
    final j = await s.a.store.postTransaction(
      s.chart.expense('9.00', payee: 'Shop'),
    );
    await s.a.sync();
    await s.b.sync();

    await s.a.store.annotateTransaction(j.id, payee: 'Corner Shop');
    await s.b.store.annotateTransaction(j.id, notes: 'milk');
    final bankA = s.a.store.account(s.chart.bank)!;
    final bankB = s.b.store.account(s.chart.bank)!;
    await s.a.store.updateAccount(bankA.copyWith(name: 'Bills'));
    await s.b.store.updateAccount(bankB.copyWith(includeInForecast: false));
    expect((await s.a.sync()).push.accepted, 2);
    // Both devices created the annotation offline: the fields still merge.
    expect((await s.b.sync()).push.accepted, 2);
    await s.a.sync();
    for (final device in [s.a, s.b]) {
      final journal = device.store.journal(j.id)!;
      expect(journal.payee, 'Corner Shop');
      expect(journal.notes, 'milk');
      final bank = device.store.account(s.chart.bank)!;
      expect(bank.name, 'Bills');
      expect(bank.includeInForecast, isFalse);
    }

    await s.a.store.updateAccount(
      s.a.store.account(s.chart.bank)!.copyWith(name: 'X'),
    );
    await s.b.store.updateAccount(
      s.b.store.account(s.chart.bank)!.copyWith(name: 'Y'),
    );
    await s.a.sync();
    expect((await s.b.sync()).push.conflicts, 1);
    final review = s.b.store.openReviewItems().single;
    expect(review.fields, ['name']);
    expect(s.b.store.account(s.chart.bank)!.name, 'X');
    await s.b.store.resolveWithFields(review.id, {'name': 'Y'});
    await s.b.sync();
    await s.a.sync();
    expect(s.a.store.account(s.chart.bank)!.name, 'Y');
  });

  e2eTest('a receipt image uploads through object storage and reaches the '
      'other device after its scan', () async {
    final s = await twoDevices();
    final assetId = await saveReceipt(s.a);
    await s.a.sync(uploadAssets: false);
    await s.b.sync(uploadAssets: false);

    final pending = s.b.store.vault.asset(assetId)!;
    expect(pending.imagePending, isTrue);
    expect(pending.sha256, s.a.store.vault.asset(assetId)!.sha256);
    await expectLater(
      s.b.client.downloadAsset(assetId),
      throwsA(isA<AssetNotYetAvailableException>()),
    );

    final uploads = await s.a.client.uploadAssets();
    expect(uploads.uploaded, [assetId]);
    expect(s.a.store.vault.asset(assetId)!.cloudConfirmedAt, isNotNull);
    await eventually(() => s.b.client.downloadAsset(assetId));
    expect(await s.b.store.vault.readAsset(assetId), jpegBytes(4000));

    // Completing again is a no-op.
    final receiptId = s.a.store.vault.asset(assetId)!.ownerId;
    final again = await s.a.call(
      'POST',
      '/v1/receipts/$receiptId/complete',
      body: {'assetId': assetId},
    );
    expect(again.status, 200);
    expect((again.body! as Map)['status'], 'available');
  });

  e2eTest('A17: another user cannot read the receipt', () async {
    final s = await twoDevices();
    final assetId = await saveReceipt(s.a);
    await s.a.sync();
    final receiptId = s.a.store.vault.asset(assetId)!.ownerId;
    await s.b.sync();
    await eventually(() => s.b.client.downloadAsset(assetId));

    final mallory = await device('mallory', newUser('mallory'));
    final own = await mallory.client.createRemoteWorkspace(name: 'Mine');
    await mallory.register(own);
    final path = '/v1/receipts/$receiptId/assets/$assetId/download';

    final viaOwn = await mallory.call('GET', path);
    expect(viaOwn.status, 404);
    final viaTheirs = await mallory.call(
      'GET',
      path,
      headers: {'x-workspace-id': s.workspace.id},
    );
    expect(viaTheirs.status, 404);
    expect((viaTheirs.body! as Map)['error'], 'WORKSPACE_NOT_FOUND');
    final viaTheirDevice = await mallory.call(
      'GET',
      '/v1/sync/changes',
      headers: {'x-device-id': s.a.deviceId, 'x-workspace-id': ''},
    );
    expect(viaTheirDevice.status, 403);
    expect((viaTheirDevice.body! as Map)['error'], 'DEVICE_NOT_AUTHORISED');
    final intent = await mallory.call(
      'POST',
      '/v1/receipts/upload-intents',
      body: {
        'receiptId': receiptId,
        'assetId': newId(),
        'kind': 'source',
        'contentType': 'image/jpeg',
        'sizeBytes': 10,
        'sha256': 'a' * 64,
      },
    );
    expect(intent.status, 404);
    expect((intent.body! as Map)['error'], 'RECEIPT_NOT_FOUND');
  });

  e2eTest(
    'journal rejections reach the client with the server codes',
    () async {
      final s = await twoDevices();
      // B deletes an unused category that A then posts to while offline.
      await s.b.store.deleteEntity('category', s.chart.dining);
      expect((await s.b.sync()).push.accepted, 1);
      final stale = await s.a.store.postTransaction(
        s.chart.expense('5.00', category: s.chart.dining),
      );
      final report = await s.a.sync();
      expect(report.push.rejected, 1);
      final review = s.a.store.openReviewItems().single;
      expect(review.kind, ReviewKind.rejected);
      expect(review.entity, EntityRef('journal', stale.id));
      expect(review.errors, contains('UNKNOWN_LEDGER_ACCOUNT'));
      expect(s.a.store.journal(stale.id), isNull);

      // Commands the local rules would never produce.
      SyncCommand post(Map<String, Object?> journal) => SyncCommand(
        commandId: newId(),
        workspaceId: s.workspace.id,
        deviceId: s.a.deviceId,
        type: CommandType.journalPost,
        entityType: 'journal',
        entityId: journal['id']! as String,
        baseRevision: 0,
        payload: {'journal': journal},
      );
      Map<String, Object?> journal({
        String currency = 'AUD',
        int debit = 500,
        int credit = -500,
      }) => {
        'id': newId(),
        'type': 'expense',
        'status': 'posted',
        'effectiveDate': '2026-07-05',
        'enteredAt': '2026-07-05T01:02:03Z',
        'currency': currency,
        'postings': [
          {'account': s.chart.groceries, 'amountMinor': debit},
          {'account': s.chart.bank, 'amountMinor': credit},
        ],
        'accountId': s.chart.bank,
        'amountMinor': debit,
        'tags': <String>[],
      };
      final commands = [
        post(journal(credit: -400)),
        post(journal(currency: 'USD')),
        post({...journal(), 'effectiveDate': 'not a date'}),
        post({...journal(), 'status': 'reversed'}),
      ];
      final response = await s.a.client.transport.postJson(
        '/v1/sync/commands',
        {
          'commands': [for (final c in commands) c.toJson()],
        },
      );
      final results = [
        for (final r
            in (response['results'] as List).cast<Map<String, Object?>>())
          CommandResult.fromJson(r.cast<String, Object?>()),
      ];
      expect(
        results.map((r) => r.status),
        everyElement(CommandStatus.validationFailed),
      );
      expect(results[0].errors, contains('UNBALANCED'));
      expect(results[1].errors, contains('CURRENCY_MISMATCH'));
      expect(results[2].errors, ['INVALID_JOURNAL']);
      expect(results[3].errors, contains('INVALID_STATUS'));
    },
  );

  e2eTest('A15: a device back after the tombstone horizon rebuilds without '
      'resurrecting deleted entities', () async {
    final s = await twoDevices();
    final g1 = newId();
    final g2 = newId();
    for (final id in [g1, g2]) {
      await s.a.store.upsertEntity('goal', id, {
        'id': id,
        'name': 'Goal',
        'targetMinor': 100000,
      });
    }
    await s.a.sync();
    await s.b.sync();

    // B is away and edits both goals.
    await s.b.store.upsertEntity('goal', g1, {
      ...s.b.store.entity('goal', g1)!.json,
      'notes': 'from B',
    });
    await s.b.store.upsertEntity('goal', g2, {
      ...s.b.store.entity('goal', g2)!.json,
      'name': 'Renamed on B',
    });
    // A changes g1 and deletes g2.
    await s.a.store.upsertEntity('goal', g1, {
      ...s.a.store.entity('goal', g1)!.json,
      'targetMinor': 250000,
    });
    await s.a.store.deleteEntity('goal', g2);
    await s.a.sync();

    // The e2e profile's horizon is 20 seconds and purges every 2 seconds.
    await Future<void>.delayed(const Duration(seconds: 24));

    final report = await s.b.sync();
    expect(report.pull.rebuilt, isTrue);
    expect(report.pull.heldForReview, 1);
    expect(s.b.store.entity('goal', g2), isNull);
    // Adding a field the server never had merges with A's change of g1.
    final review = s.b.store.openReviewItems().single;
    expect(review.kind, ReviewKind.deletedRemotely);
    expect(review.entity, EntityRef('goal', g2));
    expect(review.localState!['name'], 'Renamed on B');
    final goal = s.b.store.entity('goal', g1)!.json;
    expect(goal['targetMinor'], 250000);
    expect(goal['notes'], 'from B');

    await s.a.sync();
    expect(s.a.store.entity('goal', g1)!.json['notes'], 'from B');
    expect(s.a.store.entity('goal', g2), isNull);
  });

  e2eTest(
    'households: a member sees shared accounts but never private ones',
    () async {
      final owner = await device('owner', newUser('owner'));
      final joint = Account(
        id: newId(),
        name: 'Joint',
        type: AccountType.transaction,
        sharing: AccountSharing.shared,
      );
      final mine = Account(
        id: newId(),
        name: 'Mine',
        type: AccountType.savings,
      );
      await owner.store.createAccount(joint);
      await owner.store.createAccount(mine);
      final workspace = await owner.client.createRemoteWorkspace(name: 'Home');
      await owner.join(workspace);

      final invitation = await HouseholdClient.of(owner.client)
          .invite(workspace.id);
      final partner = await device('partner', newUser('partner'));
      final role = await HouseholdClient.of(partner.client)
          .accept(InvitationCode.parse(invitation.code!));
      expect(role, HouseholdRole.member);
      await partner.join(workspace);

      expect(partner.store.account(joint.id)?.name, 'Joint');
      expect(partner.store.account(mine.id), isNull);
      final members = await HouseholdClient.of(owner.client)
          .members(workspace.id);
      expect(members.map((m) => m.role).toSet(), {
        HouseholdRole.owner,
        HouseholdRole.member,
      });
    },
  );

  e2eTest(
    'bank feeds: sandbox proposals are posted only when accepted',
    () async {
      final s = await twoDevices();
      final feeds = BankFeedClient.of(s.a.client);
      final connection = await feeds.connect(
        provider: 'sandbox',
        purpose: 'Suggest entries from my bank transactions',
      );
      expect(connection.consentStatus, BankConsentStatus.active);
      expect(connection.sharedAccounts, hasLength(2));

      var proposals = <BankProposal>[];
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (proposals.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        proposals = await feeds.proposals(connection.id);
      }
      expect(proposals, isNotEmpty, reason: 'the backfill proposes entries');
      final balanceBefore = s.a.store.displayBalance(s.chart.bank);

      final purchase = proposals.firstWhere((p) => p.isMoneyOut && !p.pending);
      final journal = await s.a.store.postTransaction(
        s.chart.expense(
          Money(-purchase.amountMinor, Currency.aud).toDecimalString(),
          payee: purchase.description,
        ),
      );
      await s.a.sync();
      await feeds.accept(
        connection.id,
        purchase.recordId,
        journalId: journal.id,
      );
      final other = proposals.firstWhere(
        (p) => p.recordId != purchase.recordId,
      );
      await feeds.dismiss(connection.id, other.recordId);

      final open = await feeds.proposals(connection.id);
      expect(open.map((p) => p.recordId), isNot(contains(purchase.recordId)));
      expect(open.map((p) => p.recordId), isNot(contains(other.recordId)));
      expect(
        s.a.store.displayBalance(s.chart.bank),
        balanceBefore - Money(-purchase.amountMinor, Currency.aud),
        reason: 'only the accepted proposal reached the ledger',
      );
      await expectLater(
        feeds.accept(connection.id, purchase.recordId, journalId: journal.id),
        throwsA(httpError(409, 'PROPOSAL_DECIDED')),
      );
      final revoked = await feeds.revoke(connection.id);
      expect(revoked.consentStatus, BankConsentStatus.revoked);
    },
  );
}
