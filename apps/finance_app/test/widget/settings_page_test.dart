import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/appearance.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/platform/capabilities.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
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
AppServices _servicesFor(
  Directory dir, {
  PlatformCapabilities? capabilities,
  TextRecogniser? textRecogniser,
  FileExporter? fileExporter,
}) {
  final base = testServices();
  return AppServices(
    capabilities: capabilities ?? base.capabilities,
    scanner: base.scanner,
    fileImporter: base.fileImporter,
    fileExporter: fileExporter ?? base.fileExporter,
    shareInbox: base.shareInbox,
    notifications: base.notifications,
    textRecogniser: textRecogniser ?? base.textRecogniser,
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

  Future<void> pump(
    WidgetTester tester,
    Appearance? appearance, {
    AppServices Function(Directory dir)? services,
  }) async {
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
        services: (services ?? _servicesFor)(dir),
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

  testWidgets('without Tesseract the desktop says what to install', (
    tester,
  ) async {
    await pump(
      tester,
      null,
      services: (dir) => _servicesFor(
        dir,
        capabilities: PlatformCapabilities.forPlatform(TargetPlatform.linux),
        textRecogniser: TesseractTextRecogniser(),
      ),
    );
    expect(
      find.text(
        'Reading text needs Tesseract with English language data installed; '
        'receipts are kept and details entered by hand',
      ),
      findsOneWidget,
    );
  });

  group('saving things out', () {
    late Directory out;

    setUp(() async => out = await Directory.systemTemp.createTemp('saved'));
    tearDown(() => out.delete(recursive: true));

    Future<void> openAndTap(WidgetTester tester, String title) async {
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      // Real file writes finish outside the test's clock, a step at a time.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a year pack is chosen, written and reported', (tester) async {
      final exporter = FolderExporter(out);
      await pump(
        tester,
        null,
        services: (dir) => _servicesFor(dir, fileExporter: exporter),
      );
      await openAndTap(tester, 'Financial year pack');
      await tester.tap(find.text(state.financialYears.first.label));
      await settle(tester);
      final name = 'finance-${state.financialYears.first.label}';
      expect(exporter.exported, [name]);
      expect(File('${out.path}/$name/summary.csv').existsSync(), isTrue);
      expect(find.textContaining('Saved the'), findsOneWidget);
    });

    testWidgets('CSV goes through the exporter', (tester) async {
      final exporter = FolderExporter(out);
      await pump(
        tester,
        null,
        services: (dir) => _servicesFor(dir, fileExporter: exporter),
      );
      await openAndTap(tester, 'Export transactions (CSV)');
      await settle(tester);
      expect(exporter.exported.single, endsWith('.csv'));
      expect(find.text('Transactions exported'), findsOneWidget);
    });

    testWidgets('receipts go through the exporter', (tester) async {
      final exporter = FolderExporter(out);
      await pump(
        tester,
        null,
        services: (dir) => _servicesFor(dir, fileExporter: exporter),
      );
      await openAndTap(tester, 'Export receipts');
      await settle(tester);
      expect(exporter.exported.single, startsWith('receipts-'));
      expect(find.textContaining('Exported 0 receipt files'), findsOneWidget);
    });

    testWidgets('backing out says nothing', (tester) async {
      await pump(
        tester,
        null,
        services: (dir) => _servicesFor(
          dir,
          fileExporter: FolderExporter(out, outcome: ExportOutcome.cancelled),
        ),
      );
      await openAndTap(tester, 'Export transactions (CSV)');
      await settle(tester);
      expect(find.text('Transactions exported'), findsNothing);
    });

    testWidgets('a failure is explained, not swallowed', (tester) async {
      await pump(
        tester,
        null,
        services: (dir) => _servicesFor(dir, fileExporter: _FailingExporter()),
      );
      await openAndTap(tester, 'Export transactions (CSV)');
      await settle(tester);
      expect(find.textContaining('Export failed'), findsOneWidget);
    });
  });
}

class _FailingExporter implements FileExporter {
  @override
  Future<ExportOutcome> exportFile(
    String name,
    Future<void> Function(File file) write,
  ) => throw const FileSystemException('no room');

  @override
  Future<ExportOutcome> exportFolder(
    String name,
    Future<void> Function(Directory folder) write,
  ) => throw const FileSystemException('no room');
}
