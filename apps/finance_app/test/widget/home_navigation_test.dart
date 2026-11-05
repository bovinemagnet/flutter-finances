import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/home_screen.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// Test services whose workspace is [dir], which the Settings page reads.
AppServices _servicesFor(Directory dir) {
  final base = testServices();
  return AppServices(
    capabilities: base.capabilities,
    scanner: base.scanner,
    fileImporter: base.fileImporter,
    fileExporter: base.fileExporter,
    shareInbox: base.shareInbox,
    notifications: base.notifications,
    textRecogniser: base.textRecogniser,
    workspaceDirectory: dir,
    authenticator: base.authenticator,
  );
}

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;
  late List<String> platformCalls;

  setUp(() async => dir = await Directory.systemTemp.createTemp('home_nav'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
    });
    tester.view.physicalSize = const Size(411, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    platformCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: _servicesFor(dir),
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String chip) async {
    final button = find.widgetWithText(ActionChip, chip);
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Finder title(String text) => find.widgetWithText(AppBar, text);

  for (final page in ['Reports', 'Accounts', 'Settings']) {
    testWidgets('system back from $page returns to Overview', (tester) async {
      await pump(tester);
      await open(tester, page);
      expect(title(page), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(title('Overview'), findsOneWidget);
      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    });

    testWidgets('the back arrow on $page returns to Overview', (tester) async {
      await pump(tester);
      await open(tester, page);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(title('Overview'), findsOneWidget);
    });
  }

  testWidgets('system back from a tab returns to Overview', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(title('Overview'), findsOneWidget);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
  });

  testWidgets('system back from Overview leaves the app', (tester) async {
    await pump(tester);
    expect(find.byType(BackButton), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platformCalls, contains('SystemNavigator.pop'));
  });
}
