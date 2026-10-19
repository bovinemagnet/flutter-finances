import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/devices.dart';
import 'support/fake_server.dart';
import 'support/store_fixtures.dart';

Uint8List jpeg(int size, {int seed = 1}) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  for (var i = 0; i < size - 3; i++) (i * seed + 7) & 0xff,
]);

void main() {
  late TempDir temp;
  late FakeSyncServer server;
  late Device a;
  late Device b;

  setUp(() async {
    temp = TempDir();
    server = FakeSyncServer(workspaceId: 'ws-cloud');
    a = await Device.create(temp, 'a', server);
    b = await Device.create(temp, 'b', server);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    temp.dispose();
  });

  /// A has the chart and enables sync first; B joins the same workspace.
  Future<void> bothSynced() async {
    await seedChart(a.store);
    await a.enableSync(server);
    await a.sync();
    await b.enableSync(server);
    await b.sync();
  }

  Future<String> saveReceipt(
    Device d, {
    String id = 'r1',
    int size = 4000,
  }) async {
    await d.store.upsertEntity('receipt', id, {
      'id': id,
      'merchant': 'Corner Grocer',
    });
    final asset = await d.store.vault.saveAsset(
      ownerType: 'receipt',
      ownerId: id,
      kind: VaultAssetKind.source,
      contentType: 'image/jpeg',
      bytes: jpeg(size),
    );
    return asset.id;
  }

  group('bootstrap (SYNC 01)', () {
    test('a local workspace uploads its history after a preview', () async {
      await seedChart(a.store);
      await a.store.postTransaction(expense('10.00'));
      expect(() => a.client.sync(), throwsA(isA<SyncNotEnabledException>()));
      final preview = await a.client.previewBootstrap(
        remoteWorkspaceId: server.workspaceId,
      );
      expect(preview.action, BootstrapAction.uploadLocal);
      expect(preview.localCounts['account'], 2);
      expect(preview.localCounts['journal'], 1);
      expect(preview.pendingCommands, 6);
      await a.client.enableSync(preview);
      expect(a.store.settings.workspaceId, 'ws-cloud');
      expect(a.store.settings.syncMode, SyncMode.synced);
      final report = await a.sync();
      expect(report.push.accepted, 6);
      expect(a.store.pendingCommandCount, 0);
      expect(server.live('account'), hasLength(2));
      expect(server.live('journal'), hasLength(1));
      expect(a.store.isUnsynced('account', 'bank'), isFalse);
    });

    test('an empty device downloads the server workspace', () async {
      await bothSynced();
      expect(
        b.store.accounts().map((x) => x.id),
        containsAll(['bank', 'card']),
      );
      expect(b.store.categories(), hasLength(3));
    });

    test('two workspaces with data are never merged', () async {
      await seedChart(a.store);
      await a.enableSync(server);
      await a.sync();
      await seedChart(b.store);
      final preview = await b.client.previewBootstrap(
        remoteWorkspaceId: server.workspaceId,
      );
      expect(preview.action, BootstrapAction.mergeRefused);
      expect(
        () => b.client.enableSync(preview),
        throwsA(isA<WorkspaceMergeRefusedException>()),
      );
      expect(b.store.settings.syncMode, SyncMode.local);
    });

    test('a stale preview is refused', () async {
      await seedChart(a.store);
      final preview = await a.client.previewBootstrap(
        remoteWorkspaceId: server.workspaceId,
      );
      await a.store.postTransaction(expense('1.00'));
      expect(
        () => a.client.enableSync(preview),
        throwsA(isA<StalePreviewException>()),
      );
    });
  });

  group('Journey E: offline entry then reconnect', () {
    test('local saves appear at once and sync with progress later', () async {
      await bothSynced();
      server.offline = true;
      final journal = await b.store.postTransaction(
        expense('63.25', payee: 'Corner Grocer'),
      );
      final assetId = await saveReceipt(b);
      expect(b.store.displayBalance('bank'), m('-63.25'));
      expect(b.store.isUnsynced('journal', journal.id), isTrue);
      await expectLater(b.sync(), throwsA(isA<SyncNetworkException>()));
      expect(b.sleeps, const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
        Duration(milliseconds: 40),
      ]);
      expect(b.store.pendingCommandCount, 3);

      server.offline = false;
      final progress = <UploadProgress>[];
      final report = await b.client.sync(onUploadProgress: progress.add);
      expect(report.push.accepted, 3);
      expect(report.uploads!.uploaded, [assetId]);
      expect(progress.map((p) => p.phase), contains(UploadPhase.sending));
      expect(progress.last.phase, UploadPhase.completed);
      expect(progress.last.bytesSent, 4000);
      expect(b.store.isUnsynced('journal', journal.id), isFalse);
      expect(b.store.vault.asset(assetId)!.cloudConfirmedAt, isNotNull);

      await a.sync();
      expect(a.store.journal(journal.id)!.payee, 'Corner Grocer');
      expect(a.store.displayBalance('bank'), m('-63.25'));
      expect(a.store.entity('receipt', 'r1'), isNotNull);
      expect(a.store.vault.asset(assetId)!.imagePending, isTrue);
      await a.client.downloadAsset(assetId);
      expect(await a.store.vault.readAsset(assetId), jpeg(4000));
    });
  });

  group('A09: retry after a lost response', () {
    test('the original result is returned and nothing applies twice', () async {
      await bothSynced();
      final j = await a.store.postTransaction(expense('20.00'));
      server.dropCommandResponses = 1;
      final report = await a.sync();
      expect(report.push.accepted, 1);
      expect(a.sleeps, isNotEmpty);
      expect(server.live('journal'), hasLength(1));
      final entry = a.store.context.outbox.byCommandId(
        a.store.context.outbox
            .withStatus(OutboxStatus.applied)
            .last
            .command
            .commandId,
      )!;
      expect(entry.attempts, 1);
      expect(entry.result!['status'], 'previously_applied');
      await b.sync();
      expect(b.store.displayBalance('bank'), m('-20.00'));
      expect(b.store.journal(j.id), isNotNull);
    });

    test('a command whose responses were all lost is never undone '
        'and later reports previously applied', () async {
      await bothSynced();
      await a.store.postTransaction(expense('20.00'));
      server.dropCommandResponses = 4;
      await expectLater(a.sync(), throwsA(isA<SyncNetworkException>()));
      expect(server.live('journal'), hasLength(1));
      expect(a.store.lastUndoableAction, isNull);
      expect(a.store.pendingCommandCount, 1);
      final report = await a.sync();
      expect(report.push.accepted, 1);
      expect(server.live('journal'), hasLength(1));
      expect(a.store.displayBalance('bank'), m('-20.00'));
    });
  });

  group('A10: the same amount changed on two offline devices', () {
    test(
      'both proposals survive and resolution makes one correction',
      () async {
        await bothSynced();
        final original = await a.store.postTransaction(expense('100.00'));
        await a.sync();
        await b.sync();

        await a.store.correctTransaction(original.id, expense('120.00'));
        await b.store.correctTransaction(original.id, expense('130.00'));
        expect((await a.sync()).push.accepted, 1);
        final report = await b.sync();
        expect(report.push.conflicts, 1);

        final reviews = b.store.openReviewItems();
        expect(reviews, hasLength(1));
        final review = reviews.single;
        expect(review.kind, ReviewKind.conflict);
        expect(review.entity, EntityRef('journal', original.id));
        expect(review.serverState!['status'], 'reversed');
        expect(
          (review.localCommands.single.payload['replacement']
              as Map)['amountMinor'],
          13000,
        );
        // The local view now shows the accepted server version.
        expect(b.store.displayBalance('bank'), m('-120.00'));
        expect(b.store.hasOpenReview('journal', original.id), isTrue);

        await b.store.resolveKeepLocal(review.id);
        expect(b.store.openReviewItems(), isEmpty);
        expect((await b.sync()).push.accepted, 1);
        await a.sync();
        for (final device in [a, b]) {
          expect(device.store.displayBalance('bank'), m('-130.00'));
          expect(
            device.store.expenses(d('2026-07-01'), d('2026-07-31')),
            m('130.00'),
          );
        }
        final journals = server.live('journal').toList();
        for (final j in journals) {
          final postings = (j.data['postings'] as List)
              .cast<Map<String, Object?>>();
          expect(
            postings.fold<int>(0, (s, p) => s + (p['amountMinor'] as int)),
            0,
          );
        }
        final inForce = journals
            .where(
              (j) =>
                  j.data['status'] == 'posted' && j.data['type'] == 'expense',
            )
            .toList();
        expect(inForce.single.data['amountMinor'], 13000);
        expect(
          journals.where(
            (j) =>
                j.data['amountMinor'] == 12000 && j.data['type'] == 'expense',
          ),
          hasLength(1),
        );
      },
    );
  });

  test('A10: a combined amount resolves through a fresh correction', () async {
    await bothSynced();
    final original = await a.store.postTransaction(expense('100.00'));
    await a.sync();
    await b.sync();
    await a.store.correctTransaction(original.id, expense('120.00'));
    await b.store.correctTransaction(original.id, expense('130.00'));
    await a.sync();
    await b.sync();
    final review = b.store.openReviewItems().single;
    final result = await b.store.resolveWithTransaction(
      review.id,
      expense('125.00'),
    );
    expect(result!.original.amount, m('120.00'));
    expect((await b.sync()).push.accepted, 1);
    await a.sync();
    expect(a.store.displayBalance('bank'), m('-125.00'));
    expect(b.store.displayBalance('bank'), m('-125.00'));
  });

  group('metadata merge (SYNC 03)', () {
    test('different fields merge; the same field conflicts', () async {
      await bothSynced();
      final bankA = a.store.account('bank')!;
      final bankB = b.store.account('bank')!;
      await a.store.updateAccount(bankA.copyWith(name: 'Bills'));
      await b.store.updateAccount(bankB.copyWith(includeInForecast: false));
      await a.sync();
      expect((await b.sync()).push.accepted, 1);
      await a.sync();
      for (final device in [a, b]) {
        final bank = device.store.account('bank')!;
        expect(bank.name, 'Bills');
        expect(bank.includeInForecast, isFalse);
      }

      await a.store.updateAccount(a.store.account('bank')!.copyWith(name: 'X'));
      await b.store.updateAccount(b.store.account('bank')!.copyWith(name: 'Y'));
      await a.sync();
      expect((await b.sync()).push.conflicts, 1);
      final review = b.store.openReviewItems().single;
      expect(review.fields, ['name']);
      expect(review.localState!['name'], 'Y');
      expect(b.store.account('bank')!.name, 'X');
      await b.store.resolveWithFields(review.id, {'name': 'Y'});
      await b.sync();
      await a.sync();
      expect(a.store.account('bank')!.name, 'Y');
      expect(server.entity('account', 'bank')!.data['name'], 'Y');
    });
  });

  group('A15: return after tombstones expired', () {
    test('snapshot rebase keeps proposals and resurrects nothing', () async {
      await bothSynced();
      for (final id in ['g1', 'g2']) {
        await a.store.upsertEntity('goal', id, {
          'id': id,
          'name': 'Goal $id',
          'targetMinor': 100000,
        });
      }
      await a.sync();
      await b.sync();
      final receiptAsset = await saveReceipt(b, id: 'r9');

      // B is away; it edits both goals.
      await b.store.upsertEntity('goal', 'g1', {
        ...b.store.entity('goal', 'g1')!.json,
        'notes': 'from B',
      });
      await b.store.upsertEntity('goal', 'g2', {
        ...b.store.entity('goal', 'g2')!.json,
        'name': 'Renamed on B',
      });
      // A deletes g2 and changes g1; the tombstone then expires.
      await a.store.upsertEntity('goal', 'g1', {
        ...a.store.entity('goal', 'g1')!.json,
        'targetMinor': 250000,
      });
      await a.store.deleteEntity('goal', 'g2');
      await a.sync();
      server.expireTombstones();

      final report = await b.sync();
      expect(report.pull.rebuilt, isTrue);
      expect(report.pull.heldForReview, 1);
      expect(b.store.entity('goal', 'g2'), isNull);
      final review = b.store.openReviewItems().single;
      expect(review.kind, ReviewKind.deletedRemotely);
      expect(review.entity, const EntityRef('goal', 'g2'));
      expect(review.localState!['name'], 'Renamed on B');
      expect(server.entity('goal', 'g2'), isNull);

      final g1 = b.store.entity('goal', 'g1')!.json;
      expect(g1['targetMinor'], 250000);
      expect(g1['notes'], 'from B');
      expect(server.entity('goal', 'g1')!.data['notes'], 'from B');
      expect(await b.store.vault.readAsset(receiptAsset), jpeg(4000));

      await a.sync();
      expect(a.store.entity('goal', 'g1')!.json['notes'], 'from B');
      expect(a.store.entity('goal', 'g2'), isNull);
    });

    test('an interrupted rebuild resumes from the last page', () async {
      await bothSynced();
      await a.store.createCategory(
        const Category(id: 'fuel', name: 'Fuel', kind: CategoryKind.expense),
      );
      await a.sync();
      server.snapshotPageSize = 2;
      server.expireTombstones();
      server.failSnapshotAfterPages = 1;
      await expectLater(b.sync(), throwsA(isA<SyncNetworkException>()));
      final after = b.client.engine.rebuild!.after;
      expect(after, isNotNull);
      server.failSnapshotAfterPages = null;
      final report = await b.sync();
      expect(report.pull.rebuilt, isTrue);
      expect(
        server.requests.where((r) => r.contains('snapshot')).last,
        isNot(contains('after=&')),
      );
      expect(
        server.requests.any(
          (r) =>
              r.contains('snapshot') &&
              r.contains(Uri.encodeQueryComponent(after!)),
        ),
        isTrue,
      );
      expect(b.client.engine.rebuild, isNull);
      expect(b.store.accounts(), hasLength(2));
      expect(b.store.categories(), hasLength(4));
    });
  });

  group('receipt documents (SYNC 05)', () {
    test('metadata can arrive before the image', () async {
      await bothSynced();
      final assetId = await saveReceipt(a);
      await a.sync(uploadAssets: false);
      await b.sync(uploadAssets: false);
      expect(b.store.entity('receipt', 'r1'), isNotNull);
      final pending = b.store.vault.asset(assetId)!;
      expect(pending.imagePending, isTrue);
      expect(pending.sha256, a.store.vault.asset(assetId)!.sha256);
      await expectLater(
        b.client.downloadAsset(assetId),
        throwsA(isA<AssetNotYetAvailableException>()),
      );
      await a.client.uploadAssets();
      await b.client.downloadAsset(assetId);
      expect(await b.store.vault.readAsset(assetId), jpeg(4000));
    });

    test('uploads wait for their metadata to be accepted', () async {
      await bothSynced();
      final assetId = await saveReceipt(a);
      final early = await a.client.uploadAssets();
      expect(early.awaitingMetadata, [assetId]);
      expect(server.objects, isEmpty);
    });

    test('concurrency is bounded and completion is idempotent', () async {
      await bothSynced();
      await a.store.upsertEntity('receipt', 'r1', {'id': 'r1'});
      for (var i = 0; i < 5; i++) {
        await a.store.vault.saveAsset(
          ownerType: 'receipt',
          ownerId: 'r1',
          kind: VaultAssetKind.source,
          contentType: 'image/jpeg',
          bytes: jpeg(1000, seed: i + 1),
        );
      }
      server.putDelay = const Duration(milliseconds: 20);
      final report = await a.sync();
      expect(report.uploads!.uploaded, hasLength(5));
      expect(server.maxConcurrentPuts, 2);
      expect(server.completions, 5);
      final any = report.uploads!.uploaded.first;
      await a.client.transport.postJson('/v1/receipts/r1/complete', {
        'assetId': any,
      });
      expect(server.completions, 5);
    });

    test('large uploads pause on metered connections', () async {
      await bothSynced();
      final big = await saveReceipt(a, size: 1500 * 1024);
      await a.store.upsertEntity('receipt', 'r2', {'id': 'r2'});
      final small = (await a.store.vault.saveAsset(
        ownerType: 'receipt',
        ownerId: 'r2',
        kind: VaultAssetKind.derivative,
        contentType: 'image/jpeg',
        bytes: jpeg(2000),
      )).id;
      await a.sync(uploadAssets: false);
      final metered = await a.client.uploadAssets(meteredConnection: true);
      expect(metered.uploaded, [small]);
      expect(metered.pausedOnMetered, [big]);
      final later = await a.client.uploadAssets();
      expect(later.uploaded, [big]);
    });

    test('failed upload steps back off and retry', () async {
      await bothSynced();
      final assetId = await saveReceipt(a);
      await a.sync(uploadAssets: false);
      a.sleeps.clear();
      server
        ..failPath = '/v1/receipts/upload-intents'
        ..failRequests = 2;
      final report = await a.client.uploadAssets();
      expect(report.uploaded, [assetId]);
      expect(a.sleeps, const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ]);
    });
  });

  group('review of rejected and deleted targets', () {
    test(
      'an edit of an entity deleted remotely is held, not resurrected',
      () async {
        await bothSynced();
        await a.store.upsertEntity('goal', 'g1', {'id': 'g1', 'name': 'Car'});
        await a.sync();
        await b.sync();
        await a.store.deleteEntity('goal', 'g1');
        await a.sync();
        await b.store.upsertEntity('goal', 'g1', {'id': 'g1', 'name': 'Boat'});
        final report = await b.client.push();
        expect(report.conflicts, 1);
        final review = b.store.openReviewItems().single;
        expect(review.kind, ReviewKind.deletedRemotely);
        expect(b.store.entity('goal', 'g1'), isNull);
        expect(server.entity('goal', 'g1')!.deleted, isTrue);

        await b.store.resolveKeepLocal(review.id);
        await b.sync();
        final goals = server.live('goal').toList();
        expect(goals.single.data['name'], 'Boat');
        expect(goals.single.id, isNot('g1'));
      },
    );

    test('rejected commands are reverted and kept for review', () async {
      await bothSynced();
      server.workspaceId = 'someone-else';
      await b.store.upsertEntity('goal', 'g9', {'id': 'g9', 'name': 'Trip'});
      final report = await b.client.push();
      expect(report.rejected, 1);
      final review = b.store.openReviewItems().single;
      expect(review.kind, ReviewKind.rejected);
      expect(review.errors, contains('PERMISSION_DENIED'));
      expect(b.store.entity('goal', 'g9'), isNull);
      await b.store.dismissReview(review.id);
      expect(b.store.openReviewItems(), isEmpty);
    });

    test('later edits of a conflicting entity are held with it', () async {
      await bothSynced();
      await a.store.updateAccount(a.store.account('card')!.copyWith(name: 'A'));
      await a.sync();
      await b.store.updateAccount(
        b.store.account('card')!.copyWith(name: 'B1'),
      );
      await b.store.updateAccount(
        b.store.account('card')!.copyWith(name: 'B2'),
      );
      final report = await b.client.push();
      expect(report.conflicts, 1);
      final review = b.store.openReviewItems().single;
      expect(review.localCommands, hasLength(2));
      expect(review.localState!['name'], 'B2');
      expect(b.store.account('card')!.name, 'A');
      expect(b.store.pendingCommandCount, 0);
    });
  });

  test(
    'sequential local edits of one entity are rebased, not conflicted',
    () async {
      await bothSynced();
      final j = await b.store.postTransaction(
        expense('5.00', status: JournalStatus.draft),
      );
      await b.store.postTransaction(
        expense('6.00', status: JournalStatus.draft, id: j.id),
      );
      final posted = await b.store.postTransaction(expense('7.00'));
      await b.store.correctTransaction(posted.id, expense('8.00'));
      final report = await b.sync();
      expect(report.push.accepted, 4);
      expect(report.push.conflicts, 0);
      expect(server.entity('journal', j.id)!.data['amountMinor'], 600);
      expect(server.entity('journal', j.id)!.revision, 2);
      await a.sync();
      expect(a.store.displayBalance('bank'), m('-8.00'));
    },
  );
}
