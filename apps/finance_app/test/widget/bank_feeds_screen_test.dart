import 'dart:convert';
import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_app/features/sync/bank_feeds_screen.dart';
import 'package:finance_app/features/sync/extraction_consent_screen.dart';
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

const _connection = {
  'id': 'c1',
  'provider': 'sandbox',
  'institution': {'id': 'sandbox-bank', 'name': 'Sandbox Bank'},
  'sharedAccounts': [],
  'purpose': 'Suggest entries from my bank transactions',
  'consentStatus': 'active',
  'lastSuccessfulRefreshAt': '2026-10-17T00:00:00Z',
  'stale': true,
  'createdAt': '2026-10-17T00:00:00Z',
};

Map<String, Object?> _proposal(String id, String description, String status) =>
    {
      'recordId': id,
      'accountId': 'sb-everyday',
      'providerTransactionId': 'tx-$id',
      'status': 'posted',
      'amountMinor': -4250,
      'currency': 'AUD',
      'date': '2026-10-18',
      'description': description,
      'kind': 'new',
      'proposalStatus': status,
      'firstSeenAt': '2026-10-18T01:00:00Z',
    };

/// Runs [body] with a controller whose HTTP calls go to [server].
Future<void> _withController(
  WidgetTester tester,
  MockClient server,
  Future<void> Function(SyncController controller) body,
) async {
  late Directory dir;
  late AppState state;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('bank_feeds');
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
  await body(controller);
  controller.dispose();
  await tester.runAsync(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });
}

void main() {
  testWidgets('stale feeds are flagged and suggestions can be dismissed', (
    tester,
  ) async {
    final calls = <String>[];
    final bodies = <Object?>[];
    final server = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.body.isNotEmpty) bodies.add(jsonDecode(request.body));
      return switch ((request.method, request.url.path)) {
        ('GET', '/v1/bank-feeds/connections') => http.Response(
          jsonEncode([_connection]),
          200,
        ),
        ('POST', '/v1/bank-feeds/connections') => http.Response(
          jsonEncode(_connection),
          201,
        ),
        ('GET', '/v1/bank-feeds/c1/proposals') => http.Response(
          jsonEncode({
            'connectionId': 'c1',
            'proposals': [
              _proposal('r1', 'GROCER 123', 'open'),
              _proposal('r2', 'ALREADY DONE', 'accepted'),
            ],
          }),
          200,
        ),
        _ => http.Response('{}', 200),
      };
    });

    await _withController(tester, server, (controller) async {
      await tester.pumpWidget(
        MaterialApp(home: BankFeedsScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sandbox Bank'), findsOneWidget);
      expect(find.text('This feed is out of date'), findsOneWidget);
      expect(find.text('GROCER 123'), findsOneWidget);
      expect(find.text('ALREADY DONE'), findsNothing);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(calls, contains('POST /v1/bank-feeds/c1/proposals/r1/decision'));
      expect(bodies, contains(equals({'decision': 'dismissed'})));

      await tester.tap(find.text('Connect a bank'));
      await tester.pumpAndSettle();
      expect(find.textContaining('never asks'), findsOneWidget);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(bodies.last, {
        'provider': 'sandbox',
        'purpose': 'Suggest entries from my bank transactions',
      });
    });
  });

  testWidgets('cloud recognition consent repeats the offer shown', (
    tester,
  ) async {
    var status = 'none';
    final bodies = <Object?>[];
    final server = MockClient((request) async {
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map;
        bodies.add(body);
        status = body['granted'] == true ? 'granted' : 'withdrawn';
      }
      return http.Response(
        jsonEncode({
          'workspaceId': 'w',
          'status': status,
          'available': true,
          'offeredProvider': 'Example OCR',
          'offeredRetention': 'Deleted within 24 hours',
        }),
        200,
      );
    });

    await _withController(tester, server, (controller) async {
      await tester.pumpWidget(
        MaterialApp(home: ExtractionConsentScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Example OCR'), findsOneWidget);
      expect(find.text('Deleted within 24 hours'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(bodies.single, {
        'granted': true,
        'providerName': 'Example OCR',
        'disclosedRetention': 'Deleted within 24 hours',
      });
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });
  });
}
