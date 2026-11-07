import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/screens/pages/reports_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late Directory out;
  late AppState state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reports');
    out = await Directory.systemTemp.createTemp('reports_out');
  });
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
    await out.delete(recursive: true);
  });

  AppServices servicesWith(FileExporter exporter) {
    final base = testServices();
    return AppServices(
      capabilities: base.capabilities,
      scanner: base.scanner,
      fileImporter: base.fileImporter,
      fileExporter: exporter,
      shareInbox: base.shareInbox,
      notifications: base.notifications,
      textRecogniser: base.textRecogniser,
      workspaceDirectory: dir,
      authenticator: base.authenticator,
    );
  }

  Future<void> pump(
    WidgetTester tester,
    FileExporter exporter, {
    bool withEntry = true,
    bool withGoal = false,
    SyncMode syncMode = SyncMode.local,
  }) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
        syncMode: syncMode,
      );
      await store.createAccount(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
      );
      await store.createCategory(
        const Category(
          id: 'shopping',
          name: 'Shopping',
          kind: CategoryKind.expense,
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 10, 19));
      if (withEntry) {
        await state.post(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: Money(900, Currency.aud),
            effectiveDate: LocalDate(2026, 10, 1),
            splits: [Split('shopping', Money(900, Currency.aud))],
          ),
        );
      }
      if (withGoal) {
        await state.saveGoal(
          Goal(id: 'g1', name: 'Holiday', target: Money(50000, Currency.aud)),
        );
      }
    });
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: servicesWith(exporter),
        child: MaterialApp(
          home: Scaffold(body: ReportsPage(onOpenEntries: (_) {})),
        ),
      ),
    );
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

  Future<void> chooseReport(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownMenu<ReportKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> tapExport(WidgetTester tester) async {
    await tester.tap(find.text('Export CSV'));
    await settle(tester);
  }

  bool exportEnabled(WidgetTester tester) => tester
      .widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Export CSV'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      )
      .enabled;

  group('exporting a report', () {
    testWidgets('writes the report on screen and says so', (tester) async {
      final exporter = FolderExporter(out);
      await pump(tester, exporter);

      await tapExport(tester);

      expect(
        exporter.exported.single,
        'spending-by-category-2026-10-01-to-2026-10-31.csv',
      );
      expect(
        File('${out.path}/${exporter.exported.single}').readAsStringSync(),
        'Category,Spending\r\nShopping,9.00\r\n',
      );
      expect(find.text('Report exported'), findsOneWidget);
    });

    testWidgets('says when a synced workspace has changes still to send', (
      tester,
    ) async {
      final exporter = FolderExporter(out);
      await pump(tester, exporter, syncMode: SyncMode.synced);

      await tapExport(tester);

      expect(exporter.exported.single, endsWith('-includes-unsynced.csv'));
      expect(find.text('Includes changes not yet synced'), findsOneWidget);
    });

    testWidgets('does not call changes on this device unsynced', (
      tester,
    ) async {
      await pump(tester, FolderExporter(out));

      expect(find.text('Includes changes not yet synced'), findsNothing);
    });

    testWidgets('follows the report chosen', (tester) async {
      final exporter = FolderExporter(out);
      await pump(tester, exporter);
      await chooseReport(tester, 'Account balances');

      await tapExport(tester);

      expect(exporter.exported.single, startsWith('account-balances-'));
    });

    testWidgets('backing out says nothing', (tester) async {
      await pump(tester, FolderExporter(out, outcome: ExportOutcome.cancelled));

      await tapExport(tester);

      expect(find.text('Report exported'), findsNothing);
    });

    testWidgets('a failure is explained', (tester) async {
      await pump(tester, _FailingExporter());

      await tapExport(tester);

      expect(find.textContaining('Export failed'), findsOneWidget);
    });

    testWidgets('is not offered when there is nothing to export', (
      tester,
    ) async {
      await pump(tester, FolderExporter(out), withEntry: false);

      expect(exportEnabled(tester), isFalse);
    });

    testWidgets('is not offered when there is no budget to compare', (
      tester,
    ) async {
      await pump(tester, FolderExporter(out));
      await chooseReport(tester, 'Budget and actual');

      expect(exportEnabled(tester), isFalse);
    });
  });

  group('the goals report', () {
    testWidgets('shows each goal and its figures', (tester) async {
      await pump(tester, FolderExporter(out), withGoal: true);

      await chooseReport(tester, 'Goals');

      expect(find.text('Holiday'), findsWidgets);
      expect(find.text('Funding gap'), findsOneWidget);
    });

    testWidgets('can be exported', (tester) async {
      final exporter = FolderExporter(out);
      await pump(tester, exporter, withGoal: true);
      await chooseReport(tester, 'Goals');

      await tapExport(tester);

      expect(exporter.exported.single, 'goals-2026-10-19.csv');
      expect(
        File('${out.path}/${exporter.exported.single}').readAsStringSync(),
        startsWith(
          'Goal,Target,Allocated,Moved,Reserved,Funding gap\r\nHoliday,500.00,',
        ),
      );
    });

    testWidgets('says when there are no goals yet', (tester) async {
      await pump(tester, FolderExporter(out));

      await chooseReport(tester, 'Goals');

      expect(find.text('Nothing to report yet'), findsOneWidget);
      expect(exportEnabled(tester), isFalse);
    });
  });
}

class _FailingExporter implements FileExporter {
  @override
  Future<ExportOutcome> exportFile(
    String name,
    Future<void> Function(File file) write,
  ) async => throw const FileSystemException('disk full');

  @override
  Future<ExportOutcome> exportFolder(
    String name,
    Future<void> Function(Directory folder) write,
  ) async => throw const FileSystemException('disk full');
}
