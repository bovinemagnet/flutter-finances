import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:finance_app/features/sync/sync_section.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState state;
  late SyncController controller;
  var requests = 0;

  /// Behaves as the real client does for an address it cannot use.
  final client = MockClient((request) async {
    requests++;
    throw ArgumentError('No host specified in URI ${request.url}');
  });

  Future<void> start({SyncSettings? settings}) async {
    root = await Directory.systemTemp.createTemp('sync_unconfigured');
    requests = 0;
    final store = await FinanceStore.create(
      root,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      syncMode: SyncMode.synced,
    );
    state = AppState(store, today: () => LocalDate(2026, 11, 4));
    controller = SyncController(
      state,
      tokens: MemoryTokenStore(),
      settingsStore: MemorySyncSettingsStore(),
      redirectUri: 'test:/oauth',
      browserSignIn: (_) async {},
      httpClient: client,
      accessToken: () async => 'token',
      deviceName: 'phone',
      platform: 'test',
    );
    if (settings != null) await controller.saveSettings(settings);
  }

  tearDown(() async {
    controller.dispose();
    await state.store.close();
    await root.delete(recursive: true);
  });

  test('returning to the app does not sync without a service', () async {
    await start();
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 0);
    expect(controller.phase, isNot(SyncPhase.syncing));
  });

  test(
    'a failure that is not an Exception does not leave sync stuck',
    () async {
      await start(
        settings: const SyncSettings(
          serverUrl: 'finance.example.com',
          issuer: 'https://id.test',
          clientId: 'app',
        ),
      );
      await controller.syncNow();
      expect(controller.phase, SyncPhase.failed);
      expect(controller.lastError, contains('Sync paused'));
    },
  );

  testWidgets('Sync now is unavailable without a service', (tester) async {
    await tester.runAsync(start);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncSection(controller: controller)),
      ),
    );
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Sync now'),
    );
    expect(button.onPressed, isNull);
  });

  test('starting repairs a workspace that never connected', () async {
    await start();
    await controller.start();
    expect(controller.isSynced, isFalse);
    expect(state.settings.syncMode, SyncMode.local);
  });

  test('starting keeps synced mode when a service is configured', () async {
    await start(
      settings: const SyncSettings(
        serverUrl: 'https://finance.example.com',
        issuer: 'https://id.test',
        clientId: 'app',
      ),
    );
    await controller.start();
    expect(state.settings.syncMode, SyncMode.synced);
    // The sync it starts in the background ends before the controller closes.
    while (controller.phase == SyncPhase.syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}
