import 'package:finance_store/finance_store.dart';

import 'fake_server.dart';
import 'memory_key_store.dart';
import 'store_fixtures.dart';

/// One device: a local store and its sync client against [server].
class Device {
  Device._(this.name, this.store, this.client, this.sleeps);

  final String name;
  final FinanceStore store;
  final SyncClient client;

  /// Backoff delays the client asked for (tests never actually wait).
  final List<Duration> sleeps;

  static Future<Device> create(
    TempDir temp,
    String name,
    FakeSyncServer server, {
    int uploadConcurrency = 2,
    int pageSize = 500,
    String user = FakeSyncServer.defaultUser,
  }) async {
    final store = await newStore(temp.sub(name), keys: MemoryKeyStore());
    return wrap(
      name,
      store,
      server,
      uploadConcurrency: uploadConcurrency,
      pageSize: pageSize,
      user: user,
    );
  }

  /// A device around an existing [store], signed in as [user] (the fake
  /// server treats the bearer token as the subject).
  static Device wrap(
    String name,
    FinanceStore store,
    FakeSyncServer server, {
    int uploadConcurrency = 2,
    int pageSize = 500,
    String user = FakeSyncServer.defaultUser,
  }) {
    final sleeps = <Duration>[];
    final client = SyncClient(
      store,
      httpClient: server.client,
      baseUri: FakeSyncServer.base,
      accessToken: () async => user,
      retry: const RetryPolicy(
        maxAttempts: 4,
        initialDelay: Duration(milliseconds: 10),
        jitter: false,
      ),
      sleep: (d) async => sleeps.add(d),
      uploadConcurrency: uploadConcurrency,
      pageSize: pageSize,
    );
    return Device._(name, store, client, sleeps);
  }

  /// Registers this device in the server workspace.
  Future<void> register(FakeSyncServer server) => client.registerDevice(
    workspaceId: server.workspaceId,
    name: 'Device $name',
    platform: 'test',
  );

  /// Registers, previews and enables sync against the server workspace.
  Future<SyncBootstrapPreview> enableSync(FakeSyncServer server) async {
    await register(server);
    final preview = await client.previewBootstrap(
      remoteWorkspaceId: server.workspaceId,
    );
    await client.enableSync(preview);
    return preview;
  }

  Future<SyncReport> sync({bool uploadAssets = true}) =>
      client.sync(uploadAssets: uploadAssets);

  Future<void> close() => store.close();
}
