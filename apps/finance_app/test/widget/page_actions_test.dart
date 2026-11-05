import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/app/shell.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/accounts/account_editor.dart';
import 'package:finance_app/features/reports/report_view.dart';
import 'package:finance_app/screens/pages/accounts_page.dart';
import 'package:finance_app/screens/pages/budget_page.dart';
import 'package:finance_app/screens/pages/plan_page.dart';
import 'package:finance_app/screens/pages/settings_page.dart';
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

  setUp(() async => dir = await Directory.systemTemp.createTemp('actions'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(411, 800),
  }) async {
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 4));
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: _servicesFor(dir),
        child: MaterialApp(
          home: AdaptiveShell(
            selected: Destination.overview,
            onSelect: (_) {},
            onAdd: (_) {},
            body: page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect fab(WidgetTester tester, String label) =>
      tester.getRect(find.widgetWithText(FloatingActionButton, label));

  void expectClearOfShellButtons(WidgetTester tester, String label) {
    final button = fab(tester, label);
    expect(button.overlaps(fab(tester, 'Scan receipt')), isFalse);
    expect(button.overlaps(tester.getRect(find.byTooltip('Add'))), isFalse);
  }

  group('on a phone a page button is not hidden by the shell buttons', () {
    testWidgets('Add account opens the account editor', (tester) async {
      await pump(tester, const AccountsPage());
      expectClearOfShellButtons(tester, 'Add account');
      await tester.tap(
        find.widgetWithText(FloatingActionButton, 'Add account'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AccountEditor), findsOneWidget);
    });

    testWidgets('Add bill or income opens its form', (tester) async {
      await pump(tester, const PlanPage());
      expectClearOfShellButtons(tester, 'Add bill or income');
      await tester.tap(
        find.widgetWithText(FloatingActionButton, 'Add bill or income'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEditor), findsOneWidget);
      expect(find.textContaining('Add an account first'), findsOneWidget);
    });

    testWidgets('New goal opens its dialogue', (tester) async {
      await pump(tester, BudgetPage(onOpenEntries: (_) {}));
      await tester.tap(find.text('Goals'));
      await tester.pumpAndSettle();
      expectClearOfShellButtons(tester, 'New goal');
      await tester.tap(find.widgetWithText(FloatingActionButton, 'New goal'));
      await tester.pumpAndSettle();
      expect(find.text('New savings goal'), findsOneWidget);
    });
  });

  testWidgets('with no shell buttons a page button keeps its usual place', (
    tester,
  ) async {
    await pump(tester, const AccountsPage(), size: const Size(800, 900));
    expect(fab(tester, 'Add account').bottom, 900 - 16);
  });

  group('the end of a page scrolls clear of the shell buttons', () {
    Future<void> scrollToEnd(WidgetTester tester) async {
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      // A lazy list's extent grows as it builds, so repeat until it settles.
      var end = -1.0;
      while (scrollable.position.maxScrollExtent != end) {
        end = scrollable.position.maxScrollExtent;
        scrollable.position.jumpTo(end);
        await tester.pumpAndSettle();
      }
    }

    testWidgets('Settings', (tester) async {
      await pump(tester, const SettingsPage());
      await scrollToEnd(tester);
      final last = tester.getRect(find.byType(ListTile).last);
      expect(
        last.bottom,
        lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('Add')).dy),
      );
    });

    testWidgets('a report', (tester) async {
      final report = Report(
        title: 'Spending by category',
        keyLabel: 'Category',
        columns: const [ReportColumn('spent', 'Spent')],
        rows: [
          for (var i = 0; i < 30; i++)
            ReportRow(
              key: 'c$i',
              label: 'Category $i',
              amounts: {'spent': Money(100, Currency.aud)},
              journalIds: const [],
            ),
        ],
      );
      await pump(tester, ReportView(report: report, onDrillThrough: (_) {}));
      await scrollToEnd(tester);
      final last = tester.getRect(find.text('Category 29').last);
      expect(
        last.bottom,
        lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('Add')).dy),
      );
    });
  });

  testWidgets('with no accounts the page says what to do next', (tester) async {
    await pump(tester, const AccountsPage());
    expect(find.textContaining('No accounts yet'), findsOneWidget);
  });
}
