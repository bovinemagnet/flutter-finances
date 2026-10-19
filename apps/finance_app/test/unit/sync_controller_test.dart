import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
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

  Future<(AppState, SyncController)> device(String name) async {
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
}
