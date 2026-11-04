import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_app/features/accounts/account_editor.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The store's protocol-faithful fake server, shared rather than duplicated.
import '../../../../packages/finance_store/test/support/fake_server.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = LocalDate(2026, 10, 19);
  late Directory root;
  late FakeSyncServer server;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync_controller');
    server = FakeSyncServer(workspaceId: 'ws-cloud');
  });

  tearDown(() => root.delete(recursive: true));

  Future<(AppState, SyncController)> device(
    String name, {
    RetryPolicy retry = const RetryPolicy(),
    http.Client? httpClient,
  }) async {
    final store = await FinanceStore.create(
      Directory('${root.path}/$name'),
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    final state = AppState(store, today: () => today);
    final controller = SyncController(
      state,
      tokens: MemoryTokenStore(),
      settingsStore: MemorySyncSettingsStore(),
      redirectUri: 'test:/oauth',
      browserSignIn: (_) async {},
      httpClient: httpClient ?? server.client,
      accessToken: () async => FakeSyncServer.defaultUser,
      deviceName: name,
      platform: 'test',
      longPollWait: const Duration(seconds: 1),
      waitRetryDelay: const Duration(milliseconds: 20),
      pushDelay: const Duration(milliseconds: 50),
      retry: retry,
    );
    await controller.saveSettings(
      SyncSettings(
        serverUrl: FakeSyncServer.base.toString(),
        issuer: 'https://id.test',
        clientId: 'app',
      ),
    );
    return (state, controller);
  }

  // Only an upper limit: a busy machine waits longer, and a quick one no longer.
  Future<void> until(bool Function() condition, {int ms = 20000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('condition not met in ${ms}ms');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<(AppState, SyncController)> synced(
    String name, {
    RemoteWorkspace? to,
    RetryPolicy retry = const RetryPolicy(),
    http.Client? httpClient,
  }) async {
    final (s, c) = await device(name, retry: retry, httpClient: httpClient);
    final remote = to ?? (await c.remoteWorkspaces()).single;
    await c.enable(await c.prepare(existing: remote));
    return (s, c);
  }

  test('one device uploads its history and another receives it', () async {
    final (a, syncA) = await device('a');
    await a.store.createAccount(
      const Account(
        id: 'bank',
        name: 'Everyday',
        type: AccountType.transaction,
      ),
    );
    await a.post(
      TransactionDraft(
        type: TransactionType.openingBalance,
        accountId: 'bank',
        amount: Money(250000, Currency.aud),
        effectiveDate: today,
      ),
    );
    final remote = (await syncA.remoteWorkspaces()).single;
    final previewA = await syncA.prepare(existing: remote);
    expect(previewA.action, BootstrapAction.uploadLocal);
    await syncA.enable(previewA);
    expect(syncA.phase, SyncPhase.idle, reason: syncA.lastError ?? '');
    expect(a.unsyncedCount, 0);

    final (b, syncB) = await device('b');
    final previewB = await syncB.prepare(existing: remote);
    expect(previewB.action, BootstrapAction.downloadRemote);
    await syncB.enable(previewB);
    expect(b.ledger.displayBalance('bank'), Money(250000, Currency.aud));

    syncA.dispose();
    syncB.dispose();
    await a.store.close();
    await b.store.close();
  });

  test(
    'a device with data is never merged into a workspace with data',
    () async {
      final (a, syncA) = await device('a');
      await a.store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      final remote = (await syncA.remoteWorkspaces()).single;
      await syncA.enable(await syncA.prepare(existing: remote));

      final (b, syncB) = await device('b');
      await b.store.createAccount(
        const Account(id: 'cash', name: 'Wallet', type: AccountType.cash),
      );
      final preview = await syncB.prepare(existing: remote);
      expect(preview.action, BootstrapAction.mergeRefused);

      syncA.dispose();
      syncB.dispose();
      await a.store.close();
      await b.store.close();
    },
  );

  test(
    'NFR 12: an unsupported schema asks for an update and keeps changes',
    () async {
      final (a, syncA) = await device('a');
      final remote = (await syncA.remoteWorkspaces()).single;
      await syncA.enable(await syncA.prepare(existing: remote));
      server.supportedSchemaVersion = 0;
      await a.store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      await syncA.syncNow();
      expect(syncA.phase, SyncPhase.failed);
      expect(
        syncA.lastError,
        'Update the app or the sync service to keep syncing. '
        'Your changes are kept on this device.',
      );
      expect(a.unsyncedCount, 1);
      expect(a.store.openReviewItems(), isEmpty);

      server.supportedSchemaVersion = 1;
      await syncA.syncNow();
      expect(syncA.phase, SyncPhase.idle, reason: syncA.lastError ?? '');
      expect(a.unsyncedCount, 0);

      syncA.dispose();
      await a.store.close();
    },
  );

  group('waiting (NFR 05)', () {
    test(
      "an open device receives another device's change without a sync",
      () async {
        final (a, syncA) = await synced('a');
        final (b, syncB) = await synced('b');
        // At least one: device a may be waiting as well.
        await until(() => syncB.isWaiting && server.waiting >= 1);

        await a.store.createAccount(
          const Account(
            id: 'bank',
            name: 'Everyday',
            type: AccountType.transaction,
          ),
        );
        await syncA.syncNow();
        await until(
          () => b.store.accounts().any((x) => x.id == 'bank'),
          ms: 2000,
        );

        syncA.dispose();
        syncB.dispose();
        await a.store.close();
        await b.store.close();
      },
    );

    test('waiting stops when hidden and starts on resume', () async {
      final (a, syncA) = await synced('a');
      await until(() => syncA.isWaiting);

      syncA.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(syncA.isWaiting, isFalse);
      syncA.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(syncA.isWaiting, isTrue);
      // Resuming also syncs; let it finish before the store closes.
      await until(() => syncA.phase != SyncPhase.syncing);

      syncA.dispose();
      await a.store.close();
    });

    test('an older server turns waiting off', () async {
      server.supportsWait = false;
      final (a, syncA) = await synced('a');
      await until(() => !syncA.isWaiting && _waits(server) >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(syncA.isWaiting, isFalse);
      expect(_waits(server), lessThanOrEqualTo(2));

      syncA.dispose();
      await a.store.close();
    });

    test('waiting backs off while offline', () async {
      server.maxHold = const Duration(milliseconds: 20);
      final (a, syncA) = await synced(
        'a',
        retry: const RetryPolicy(maxAttempts: 1),
      );
      await until(() => syncA.isWaiting);
      server.offline = true;
      // Let the request already being held finish before counting.
      await until(() => server.waiting == 0);
      final before = _waits(server);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final during = _waits(server) - before;
      server.offline = false;
      // Retries happen (20, 40, 80, 160 ms) but not in a tight loop.
      expect(during, inInclusiveRange(2, 5));

      syncA.dispose();
      await a.store.close();
    });

    test('sign-out stops waiting', () async {
      final (a, syncA) = await synced('a');
      await until(() => syncA.isWaiting);
      await syncA.signOut();
      expect(syncA.isWaiting, isFalse);

      syncA.dispose();
      await a.store.close();
    });

    test('a failed pull asked for by a wait backs off', () async {
      final (a, syncA) = await synced(
        'a',
        retry: const RetryPolicy(maxAttempts: 1),
      );
      final (b, syncB) = await synced('b');
      await until(() => syncA.isWaiting);
      // Device a misses b's change, then its cursor expires. Device b stops
      // waiting too: the count covers every device, so while b waits it is
      // zero only for an instant between requests.
      syncA.didChangeAppLifecycleState(AppLifecycleState.hidden);
      syncB.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await until(() => server.waiting == 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.waiting, 0, reason: 'nothing is waiting any more');
      await b.store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      await syncB.syncNow();
      syncB.dispose();
      await b.store.close();
      server
        ..expireTombstones()
        ..failPath = '/v1/sync/snapshot'
        ..failRequests = 1000;

      // Every wait now asks for a pull, and every pull fails.
      syncA.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await until(() => _snapshots(server) >= 7);
      // Retries happen, each waiting at least twice as long as the last. Load
      // can only lengthen these waits, so a floor holds on any machine. The
      // first attempts are skipped, since returning to the app also syncs.
      final at = server.snapshotRequestTimes;
      expect(
        at[6].difference(at[2]),
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
        reason: 'retries are not in a tight loop',
      );

      syncA.didChangeAppLifecycleState(AppLifecycleState.hidden);
      server.failRequests = 0;
      syncA.dispose();
      await until(() => syncA.phase != SyncPhase.syncing);
      await a.store.close();
    });

    test('an unexpected error ends waiting so it can start again', () async {
      var malformed = false;
      final tampering = MockClient((request) async {
        if (malformed && request.url.queryParameters.containsKey('wait')) {
          return http.Response('[]', 200);
        }
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await server.client.send(copy));
      });
      final (a, syncA) = await synced('a', httpClient: tampering);
      await until(() => syncA.isWaiting);
      syncA.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await until(() => server.waiting == 0);
      malformed = true;

      final errors = <Object>[];
      runZonedGuarded(
        () => syncA.didChangeAppLifecycleState(AppLifecycleState.resumed),
        (e, _) => errors.add(e),
      );
      // Resuming also syncs, and that sync starts waiting again; both loops
      // meet the error and end.
      await until(() => syncA.phase == SyncPhase.idle && !syncA.isWaiting);
      expect(errors, isNotEmpty);
      expect(errors, everyElement(isA<TypeError>()));

      malformed = false;
      syncA.didChangeAppLifecycleState(AppLifecycleState.hidden);
      syncA.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(syncA.isWaiting, isTrue);

      await until(() => syncA.phase != SyncPhase.syncing);
      syncA.dispose();
      await a.store.close();
    });
  });
  group('push after a save (NFR 05)', () {
    Future<void> saveAccount(AppState s, String id) => s.saveAccount(
      AccountEdit(
        Account(id: id, name: id, type: AccountType.transaction),
        null,
        today,
      ),
    );

    int commandPosts() =>
        server.requests.where((r) => r == 'POST $_commandsUrl').length;

    test('a save is sent about a moment later', () async {
      final (a, syncA) = await synced('a');
      final before = server.commandCount;
      await saveAccount(a, 'bank');
      await until(() => server.commandCount > before, ms: 2000);
      await until(() => a.unsyncedCount == 0, ms: 2000);

      syncA.dispose();
      await a.store.close();
    });

    test('a burst of saves is one sync', () async {
      final (a, syncA) = await synced('a');
      await until(() => syncA.phase == SyncPhase.idle);
      final before = commandPosts();
      for (var i = 0; i < 3; i++) {
        await saveAccount(a, 'acc$i');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await until(() => a.unsyncedCount == 0, ms: 2000);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(commandPosts() - before, 1);

      syncA.dispose();
      await a.store.close();
    });

    test('a save during a running sync is sent when it ends', () async {
      final (a, syncA) = await synced('a');
      await until(() => syncA.phase == SyncPhase.idle);
      final assetId = await _saveReceipt(a, 'r1', notify: false);
      server.putDelay = const Duration(milliseconds: 400);
      final running = syncA.syncNow();
      // The commands are already pushed; the file upload is still running.
      await until(
        () => server.requests.any((r) => r.startsWith('PUT https://objects')),
      );
      await saveAccount(a, 'bank');
      // Past the push delay, still inside the running sync.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(syncA.phase, SyncPhase.syncing);
      await running;
      await until(() => a.unsyncedCount == 0, ms: 2000);
      await until(() => syncA.phase == SyncPhase.idle);
      // The follow-up also checks for files to upload; let it finish.
      await until(
        () => a.store.vault.asset(assetId)!.cloudConfirmedAt != null,
        ms: 4000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      syncA.dispose();
      await a.store.close();
    });

    test('a save after the push of a sync that began with more pending is '
        'still sent', () async {
      final (a, syncA) = await synced(
        'a',
        retry: const RetryPolicy(maxAttempts: 1),
      );
      await until(() => syncA.phase == SyncPhase.idle);
      server.offline = true;
      await saveAccount(a, 'first');
      await until(() => syncA.phase == SyncPhase.failed);
      expect(a.unsyncedCount, 1);
      server.offline = false;
      await _saveReceipt(a, 'r1', notify: false);
      server.putDelay = const Duration(milliseconds: 400);
      final running = syncA.syncNow();
      await until(
        () => server.requests.any((r) => r.startsWith('PUT https://objects')),
      );
      await saveAccount(a, 'second');
      await running;
      await until(() => a.unsyncedCount == 0, ms: 2000);
      await until(() => syncA.phase != SyncPhase.syncing);

      syncA.dispose();
      await a.store.close();
    });

    test('a failed sync does not retrigger itself', () async {
      final (a, syncA) = await synced(
        'a',
        retry: const RetryPolicy(maxAttempts: 1),
      );
      await until(() => syncA.phase == SyncPhase.idle);
      server.offline = true;
      final before = server.requests.length;
      await saveAccount(a, 'bank');
      await until(() => syncA.phase == SyncPhase.failed);
      int syncRequests() => server.requests
          .skip(before)
          .where((r) => r.contains('/v1/sync/') && !r.contains('wait='))
          .length;
      final failedAt = syncRequests();
      expect(failedAt, greaterThanOrEqualTo(1));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(syncRequests(), failedAt);
      server.offline = false;
      await until(() => syncA.phase != SyncPhase.syncing);

      syncA.dispose();
      await a.store.close();
    });

    test(
      'the post-save sync leaves receipt files for a separate upload',
      () async {
        final (a, syncA) = await synced('a');
        await until(() => syncA.phase == SyncPhase.idle);
        final before = server.requests.length;
        await _saveReceipt(a, 'r1');
        await until(
          () => server.requests
              .skip(before)
              .any((r) => r.contains('objects.test')),
          ms: 2000,
        );
        // The post-save sync itself did not carry the upload.
        expect(syncA.lastReport!.uploads, isNull);
        final sent = server.requests.skip(before).toList();
        final firstCommand = sent.indexWhere((r) => r == 'POST $_commandsUrl');
        final firstObject = sent.indexWhere((r) => r.contains('objects.test'));
        expect(firstCommand, greaterThanOrEqualTo(0));
        expect(firstCommand, lessThan(firstObject));

        // Let the upload finish writing its state before the store closes.
        await until(() => a.store.vault.pendingUploads().isEmpty);
        syncA.dispose();
        await a.store.close();
      },
    );
  });
}

int _waits(FakeSyncServer server) =>
    server.requests.where((r) => r.contains('wait=')).length;

int _snapshots(FakeSyncServer server) =>
    server.requests.where((r) => r.contains('/v1/sync/snapshot')).length;

String get _commandsUrl =>
    FakeSyncServer.base.resolve('/v1/sync/commands').toString();

/// Saves a receipt with a file; [notify] false keeps it from scheduling a push.
Future<String> _saveReceipt(AppState s, String id, {bool notify = true}) async {
  await s.store.upsertEntity('receipt', id, {
    'id': id,
    'merchant': 'Corner Grocer',
  });
  final asset = await s.store.vault.saveAsset(
    ownerType: 'receipt',
    ownerId: id,
    kind: VaultAssetKind.source,
    contentType: 'image/jpeg',
    bytes: Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      for (var i = 0; i < 3997; i++) (i + 7) & 0xff,
    ]),
  );
  if (notify) s.refresh();
  return asset.id;
}
