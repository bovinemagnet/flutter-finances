import 'dart:async';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/devices.dart';
import 'support/fake_server.dart';
import 'support/store_fixtures.dart';

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
    await seedChart(a.store);
    await a.enableSync(server);
    await a.sync();
    await b.enableSync(server);
    await b.sync();
  });

  tearDown(() async {
    await a.close();
    await b.close();
    temp.dispose();
  });

  Future<void> saveAccount(Device d, String id) => d.store.createAccount(
    Account(id: id, name: id, type: AccountType.savings),
  );

  Future<void> untilWaiting() async {
    while (server.waiting < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a waiting device receives a change from another device', () async {
    server.maxHold = const Duration(seconds: 5);
    final waited = b.client.waitForChanges();
    await untilWaiting();
    await saveAccount(a, 'savings');
    await a.client.push();
    final result = await waited.timeout(const Duration(seconds: 2));
    expect(result.supported, isTrue);
    expect(result.changes, greaterThanOrEqualTo(1));
    expect(b.store.accounts().map((x) => x.id), contains('savings'));
  });

  test('an empty wait applies nothing and keeps supported', () async {
    final result = await b.client.waitForChanges();
    expect(result.supported, isTrue);
    expect(result.changes, 0);
    expect(result.needsPull, isFalse);
  });

  test('a waited page is dropped when a pull moved the cursor', () async {
    server.maxHold = const Duration(seconds: 5);
    final waited = b.client.waitForChanges();
    await untilWaiting();
    final gate = server.waitedResponseGate = Completer<void>();
    await saveAccount(a, 'savings');
    await a.client.push();
    final pulled = await b.client.pull();
    gate.complete();
    final result = await waited.timeout(const Duration(seconds: 2));
    expect(pulled.changes, greaterThanOrEqualTo(1));
    expect(result.changes, 0);
    expect(result.needsPull, isFalse);
    expect(b.store.accounts().map((x) => x.id), contains('savings'));
    // The cursor is where the pull left it.
    expect((await b.client.pull()).changes, 0);
  });

  test('an older server is reported as not supporting wait', () async {
    server.supportsWait = false;
    await saveAccount(a, 'savings');
    await a.client.push();
    final result = await b.client.waitForChanges();
    expect(result.supported, isFalse);
    expect(result.changes, 0);
    expect(b.store.accounts().map((x) => x.id), isNot(contains('savings')));
    // The cursor did not move, so a pull still finds the change.
    expect((await b.client.pull()).changes, greaterThanOrEqualTo(1));
  });

  test('a push is not blocked by a wait', () async {
    server.maxHold = const Duration(seconds: 5);
    final waited = b.client.waitForChanges();
    await untilWaiting();
    expect(server.waiting, 1);
    await saveAccount(b, 'mine');
    await b.client.push().timeout(const Duration(seconds: 2));
    // The device's own change wakes the wait; it must still finish.
    await waited.timeout(const Duration(seconds: 2));
  });

  test('an expired cursor asks for a pull', () async {
    await saveAccount(a, 'savings');
    await a.client.push();
    server.expireTombstones();
    final result = await b.client.waitForChanges();
    expect(result.needsPull, isTrue);
  });

  test('a wait needs sync to be enabled', () async {
    final local = await Device.create(temp, 'local', server);
    addTearDown(local.close);
    expect(
      () => local.client.waitForChanges(),
      throwsA(isA<SyncNotEnabledException>()),
    );
  });
}
