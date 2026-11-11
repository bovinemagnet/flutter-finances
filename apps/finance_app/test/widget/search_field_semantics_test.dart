import 'dart:io';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipts_page.dart';
import 'package:finance_app/features/transactions/transaction_list.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/sample_world.dart';
import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// A screen reader should stop once at each search field, on the field that
/// can be typed into, and hear its name there (#16).
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  /// Checks the text fields as the platform receives them: a node merged into
  /// its parent is not sent on its own, and its parent carries its data.
  void expectOneLabelledSearchField(WidgetTester tester, String label) {
    final fields = <SemanticsData>[];
    void visit(SemanticsNode node) {
      if (!node.isMergedIntoParent) {
        final data = node.getSemanticsData();
        if (data.flagsCollection.isTextField) fields.add(data);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(
      tester
          .renderObject(find.byType(Scaffold))
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!,
    );
    expect(fields, hasLength(1), reason: 'text field nodes');
    final data = fields.single;
    expect(data.label, startsWith(label));
    expect(data.hasAction(SemanticsAction.focus), isTrue, reason: 'editable');
  }

  testWidgets('the transactions search is one labelled field', (tester) async {
    final semantics = tester.ensureSemantics();
    final world = SampleWorld();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransactionList(
            items: const [],
            categories: world.chart.categories.toList(),
            onOpen: (_) {},
            onMarkReviewed: (_) {},
            onCategorise: (_, _) {},
          ),
        ),
      ),
    );
    expectOneLabelledSearchField(tester, 'Search transactions');
    semantics.dispose();
  });

  testWidgets('the receipts search is one labelled field', (tester) async {
    final semantics = tester.ensureSemantics();
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('search_semantics');
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 12));
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await state.store.close();
        await dir.delete(recursive: true);
      });
    });
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
        child: const MaterialApp(home: Scaffold(body: ReceiptsPage())),
      ),
    );
    await tester.pumpAndSettle();
    expectOneLabelledSearchField(tester, 'Search receipts');
    semantics.dispose();
  });
}
