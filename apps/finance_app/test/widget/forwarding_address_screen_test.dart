import 'dart:convert';
import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:finance_app/data/sync_controller.dart';
import 'package:finance_app/features/sync/forwarding_address_screen.dart';
import 'package:finance_app/features/sync/sync_section.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// A server holding one member's address, as the real endpoints behave.
class _Server {
  String? address;
  var viewer = false;
  var available = true;
  var statusFails = false;
  var replacements = 0;
  List<Map<String, Object?>> recent = const [];
  final calls = <String>[];

  late final client = MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    final path = request.url.path;
    if (path == '/v1/inbound-mail/status') {
      if (statusFails) return http.Response('{"error":"UNAVAILABLE"}', 400);
      return _json(200, {'available': available});
    }
    if (path.endsWith('/inbound-documents')) {
      return _json(200, {
        'documents': <Object>[],
        'notices': <Object>[],
        'recent': recent,
      });
    }
    if (!path.endsWith('/inbound-address')) return http.Response('', 404);
    if (viewer) return _json(403, {'error': 'READ_ONLY', 'message': 'No'});
    switch (request.method) {
      case 'GET':
        return address == null
            ? _json(404, {'error': 'NOT_FOUND'})
            : _json(200, _body());
      case 'PUT':
        replacements++;
        address = 'token$replacements@receipts.test';
        return _json(200, _body());
      case 'DELETE':
        address = null;
        return http.Response('', 204);
    }
    return http.Response('', 404);
  });

  Map<String, Object?> _body() => {
    'address': address,
    'createdAt': '2026-11-04T00:00:00Z',
  };

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status);
}

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  Future<void> withController(
    WidgetTester tester,
    _Server server,
    Future<void> Function(SyncController controller) body, {
    SyncMode mode = SyncMode.synced,
    bool complete = true,
  }) async {
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('forwarding');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
        syncMode: mode,
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
    });
    final controller = SyncController(
      state,
      tokens: MemoryTokenStore(),
      settingsStore: MemorySyncSettingsStore(),
      redirectUri: 'test:/oauth',
      browserSignIn: (_) async {},
      httpClient: server.client,
      accessToken: () async => 'token',
      retry: const RetryPolicy(maxAttempts: 1),
    );
    if (complete) {
      await tester.runAsync(
        () => controller.saveSettings(
          const SyncSettings(
            serverUrl: 'https://sync.test',
            issuer: 'https://id.test',
            clientId: 'app',
          ),
        ),
      );
    }
    tester.view.physicalSize = const Size(411, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await body(controller);
    controller.dispose();
    await tester.runAsync(() async {
      await state.store.close();
      await dir.delete(recursive: true);
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    SyncController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ForwardingAddressScreen(controller: controller)),
    );
    await settle(tester);
  }

  testWidgets('explains what happens before turning on', (tester) async {
    final server = _Server();
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      expect(find.textContaining('outside email service'), findsOneWidget);
      expect(find.textContaining('sync service'), findsOneWidget);
      expect(
        find.textContaining('body of each email is discarded'),
        findsOneWidget,
      );
      expect(find.textContaining('shared with your workspace'), findsOneWidget);
      expect(find.textContaining('entered by hand'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Turn on'), findsOneWidget);
      expect(server.calls, isNot(contains(endsWith('PUT'))));
    });
  });

  testWidgets('turning on shows the address, which can be copied', (
    tester,
  ) async {
    final server = _Server();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
      await settle(tester);
      expect(find.text('token1@receipts.test'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy address'));
      await settle(tester);
      expect(copied, 'token1@receipts.test');
    });
  });

  testWidgets('replacing warns that the old address stops working', (
    tester,
  ) async {
    final server = _Server()..address = 'old@receipts.test';
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Replace address'));
      await tester.pumpAndSettle();
      expect(find.textContaining('will be dropped'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.text('old@receipts.test'), findsOneWidget);
      expect(server.replacements, 0);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Replace address'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
      await settle(tester);
      expect(find.text('token1@receipts.test'), findsOneWidget);
    });
  });

  testWidgets('turning off keeps what is waiting, and says so', (tester) async {
    final server = _Server()..address = 'old@receipts.test';
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      await tester.tap(find.widgetWithText(TextButton, 'Turn off'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already waiting can still'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await settle(tester);
      expect(server.address, isNull);
      expect(find.widgetWithText(FilledButton, 'Turn on'), findsOneWidget);
    });
  });

  testWidgets('explains that uncollected documents expire', (tester) async {
    final server = _Server()..address = 'old@receipts.test';
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      expect(find.textContaining('within 30 days'), findsOneWidget);
    });
  });

  testWidgets('recent emails say what became of them', (tester) async {
    Map<String, Object?> entry(String sender, String outcome) => {
      'messageId': sender,
      'sender': sender,
      'receivedAt': '2026-11-04T00:00:00Z',
      'outcome': outcome,
      'rejections': <Object>[],
    };
    final server = _Server()
      ..address = 'old@receipts.test'
      ..recent = [
        entry('a@example.com', 'documents'),
        entry('b@example.com', 'no_attachment'),
        entry('c@example.com', 'rejected'),
        entry('d@example.com', 'rate_limited'),
        entry('e@example.com', 'failed'),
        entry('f@example.com', 'processing'),
      ];
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      expect(find.text('Recent emails'), findsOneWidget);
      expect(find.text('a@example.com'), findsOneWidget);
      expect(find.textContaining('Attachments received'), findsOneWidget);
      expect(find.textContaining('No attachment'), findsOneWidget);
      expect(find.textContaining('Nothing could be kept'), findsOneWidget);
      expect(find.textContaining('Over the daily limit'), findsOneWidget);
      expect(find.textContaining('Could not be processed'), findsOneWidget);
      expect(find.textContaining('Still being handled'), findsOneWidget);
    });
  });

  testWidgets('with nothing forwarded yet there is no empty list', (
    tester,
  ) async {
    final server = _Server()..address = 'old@receipts.test';
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      expect(find.text('Recent emails'), findsNothing);
    });
  });

  testWidgets('a viewer is told why not', (tester) async {
    final server = _Server()..viewer = true;
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      expect(find.textContaining('Viewers cannot'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Turn on'), findsNothing);
    });
  });

  testWidgets('every control is labelled and big enough', (tester) async {
    final server = _Server()..address = 'old@receipts.test';
    final handle = tester.ensureSemantics();
    await withController(tester, server, (controller) async {
      await pumpScreen(tester, controller);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
    handle.dispose();
  });

  group('the Settings tile', () {
    Future<void> pumpSection(
      WidgetTester tester,
      SyncController controller,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SyncSection(controller: controller),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    const tile = 'Forward receipts by email';

    testWidgets('appears when synced and available', (tester) async {
      final server = _Server();
      await withController(tester, server, (controller) async {
        await pumpSection(tester, controller);
        expect(find.text(tile), findsOneWidget);
        await tester.tap(find.text(tile));
        await settle(tester);
        expect(find.byType(ForwardingAddressScreen), findsOneWidget);
      });
    });

    testWidgets('is hidden when the server does not offer it', (tester) async {
      final server = _Server()..available = false;
      await withController(tester, server, (controller) async {
        await pumpSection(tester, controller);
        expect(find.text(tile), findsNothing);
      });
    });

    testWidgets('is hidden, without an error, if the check fails', (
      tester,
    ) async {
      final server = _Server()..statusFails = true;
      await withController(tester, server, (controller) async {
        await pumpSection(tester, controller);
        expect(find.text(tile), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('is hidden with no service set up', (tester) async {
      final server = _Server();
      await withController(tester, server, (controller) async {
        await pumpSection(tester, controller);
        expect(find.text(tile), findsNothing);
        expect(server.calls, isEmpty);
      }, complete: false);
    });

    testWidgets('is hidden when sync is off', (tester) async {
      final server = _Server();
      await withController(tester, server, (controller) async {
        await pumpSection(tester, controller);
        expect(find.text(tile), findsNothing);
      }, mode: SyncMode.local);
    });
  });
}
