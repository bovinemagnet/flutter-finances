import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/appearance.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/screens/pages/settings_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// Test services whose workspace is [dir], which the page reads.
AppServices _servicesFor(Directory dir) {
  final base = testServices();
  return AppServices(
    capabilities: base.capabilities,
    scanner: base.scanner,
    fileImporter: base.fileImporter,
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

  setUp(() async => dir = await Directory.systemTemp.createTemp('settings'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Appearance? appearance) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 10, 20));
    });
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: _servicesFor(dir),
        appearance: appearance,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings offer the light and dark choice', (tester) async {
    final appearance = Appearance.inMemory();
    await pump(tester, appearance);
    expect(find.text('Appearance'), findsOneWidget);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appearance.value, ThemeMode.dark);
  });

  testWidgets('without a device appearance the choice is hidden', (
    tester,
  ) async {
    await pump(tester, null);
    expect(find.text('Appearance'), findsNothing);
  });
}
