import 'dart:convert';
import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_app/features/sync/household_screen.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  testWidgets('owners see members, invite and revoke', (tester) async {
    late Directory dir;
    late AppState state;
    final calls = <String>[];
    final pending = <Map<String, Object?>>[];
    final server = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      final path = request.url.path;
      if (path.endsWith('/members')) {
        return http.Response(
          jsonEncode([
            {
              'userId': 'u1',
              'role': 'owner',
              'joinedAt': '2026-10-01T00:00:00Z',
              'you': true,
            },
            {
              'userId': 'u2',
              'role': 'member',
              'joinedAt': '2026-10-02T00:00:00Z',
              'you': false,
            },
          ]),
          200,
        );
      }
      if (request.method == 'POST' && path.endsWith('/invitations')) {
        final invitation = {
          'id': 'i1',
          'workspaceId': 'w',
          'role': 'member',
          'status': 'pending',
          'createdAt': '2026-10-20T00:00:00Z',
          'expiresAt': '2026-10-27T00:00:00Z',
        };
        pending.add(invitation);
        return http.Response(jsonEncode({...invitation, 'token': 'tok'}), 201);
      }
      if (request.method == 'GET' && path.endsWith('/invitations')) {
        return http.Response(jsonEncode(pending), 200);
      }
      if (request.method == 'DELETE') pending.clear();
      return http.Response('', 204);
    });
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('household');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 10, 20));
    });
    final controller = SyncController(
      state,
      tokens: MemoryTokenStore(),
      settingsStore: MemorySyncSettingsStore(),
      redirectUri: 'test:/oauth',
      browserSignIn: (_) async {},
      httpClient: server,
      accessToken: () async => 'token',
    );
    await tester.runAsync(
      () => controller.saveSettings(
        const SyncSettings(
          serverUrl: 'https://sync.test',
          issuer: 'https://id.test',
          clientId: 'app',
        ),
      ),
    );

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: HouseholdScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Member since 2026-10-02'), findsOneWidget);

    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Member'));
    await tester.pumpAndSettle();
    expect(find.text('Invitation code'), findsOneWidget);
    expect(find.textContaining('.i1.tok'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(calls, contains(startsWith('DELETE /v1/workspaces/')));
    expect(find.text('Revoke'), findsNothing);

    controller.dispose();
    await tester.runAsync(() async {
      await state.store.close();
      await dir.delete(recursive: true);
    });
  });
}
