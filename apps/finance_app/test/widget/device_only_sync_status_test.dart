import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipts_page.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/screens/home_screen.dart';
import 'package:finance_app/screens/pages/settings_page.dart';
import 'package:finance_app/screens/pages/transactions_page.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// Someone who keeps their data only on this device is never told that
/// changes are waiting to sync (#19). With sync on, the same messages show.
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  late Directory dir;
  late AppState state;

  /// A workspace in [mode] with one entry and one receipt, neither of which
  /// has reached a server.
  Future<void> createWorkspace(WidgetTester tester, SyncMode mode) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('sync_status');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
        syncMode: mode,
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
          id: 'groceries',
          name: 'Groceries',
          kind: CategoryKind.expense,
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
      await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(1350, Currency.aud),
          effectiveDate: LocalDate(2026, 11, 3),
          payee: 'Fresh Grocer',
          splits: [Split('groceries', Money(1350, Currency.aud))],
        ),
      );
      await state.receipts.capture([
        CapturedFile(
          Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
          source: CaptureSource.camera,
        ),
      ]);
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await state.store.close();
        await dir.delete(recursive: true);
      });
    });
  }

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    double height = 900,
  }) async {
    tester.view.physicalSize = Size(411, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final base = testServices();
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: AppServices(
          capabilities: base.capabilities,
          scanner: base.scanner,
          fileImporter: base.fileImporter,
          fileExporter: base.fileExporter,
          shareInbox: base.shareInbox,
          notifications: base.notifications,
          textRecogniser: base.textRecogniser,
          workspaceDirectory: dir,
          authenticator: base.authenticator,
        ),
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  final badge = find.byIcon(Icons.cloud_off_outlined);
  final overviewNote = find.textContaining('not yet synced');
  final entryTag = find.text('Not synced');
  final receiptNote = find.textContaining('Saved on this device only');
  final storageNote = find.textContaining('not yet backed up to the server');

  Future<void> scrollToStorage(WidgetTester tester) =>
      tester.scrollUntilVisible(
        find.text('Storage on this device'),
        300,
        scrollable: find.byType(Scrollable).first,
      );

  group('kept only on this device', () {
    testWidgets('the title bar and Overview do not mention syncing', (
      tester,
    ) async {
      await createWorkspace(tester, SyncMode.local);
      await pump(tester, const HomeScreen(), height: 3000);
      expect(badge, findsNothing);
      expect(find.text('YOUR MONEY'), findsOneWidget);
      expect(overviewNote, findsNothing);
    });

    testWidgets('entries are not tagged as not synced', (tester) async {
      await createWorkspace(tester, SyncMode.local);
      await pump(tester, const Scaffold(body: TransactionsPage()));
      expect(find.text('Fresh Grocer'), findsOneWidget);
      expect(entryTag, findsNothing);
    });

    testWidgets('receipts are not marked as saved on this device only', (
      tester,
    ) async {
      await createWorkspace(tester, SyncMode.local);
      await pump(tester, const Scaffold(body: ReceiptsPage()));
      expect(find.textContaining(' · Not matched'), findsOneWidget);
      expect(receiptNote, findsNothing);
    });

    testWidgets('storage does not mention backing up to a server', (
      tester,
    ) async {
      await createWorkspace(tester, SyncMode.local);
      await pump(tester, const Scaffold(body: SettingsPage()));
      await scrollToStorage(tester);
      expect(find.textContaining(' used'), findsWidgets);
      expect(storageNote, findsNothing);
    });
  });

  group('with sync on', () {
    testWidgets('the title bar and Overview count changes to sync', (
      tester,
    ) async {
      await createWorkspace(tester, SyncMode.synced);
      await pump(tester, const HomeScreen(), height: 3000);
      expect(badge, findsOneWidget);
      expect(find.text('YOUR MONEY'), findsOneWidget);
      expect(overviewNote, findsOneWidget);
    });

    testWidgets('entries are tagged until they sync', (tester) async {
      await createWorkspace(tester, SyncMode.synced);
      await pump(tester, const Scaffold(body: TransactionsPage()));
      expect(entryTag, findsOneWidget);
    });

    testWidgets('receipts are marked until they sync', (tester) async {
      await createWorkspace(tester, SyncMode.synced);
      await pump(tester, const Scaffold(body: ReceiptsPage()));
      expect(receiptNote, findsOneWidget);
    });

    testWidgets('storage says what is not yet backed up', (tester) async {
      await createWorkspace(tester, SyncMode.synced);
      await pump(tester, const Scaffold(body: SettingsPage()));
      await scrollToStorage(tester);
      expect(storageNote, findsOneWidget);
    });
  });
}
