import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

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
      httpClient: server.client,
      accessToken: () async => FakeSyncServer.defaultUser,
      deviceName: name,
      platform: 'test',
      longPollWait: const Duration(seconds: 1),
      waitRetryDelay: const Duration(milliseconds: 20),
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

  Future<void> until(bool Function() condition, {int ms = 3000}) async {
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
  }) async {
    final (s, c) = await device(name, retry: retry);
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
        await until(() => syncB.isWaiting && server.waiting == 1);

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
  });
}

int _waits(FakeSyncServer server) =>
    server.requests.where((r) => r.contains('wait=')).length;
