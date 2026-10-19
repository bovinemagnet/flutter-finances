import 'package:finance_app/features/transactions/transaction_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/sample_world.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  final world = SampleWorld();
  List<TransactionListItem> items() => [
    for (final j in world.journals.skip(1))
      TransactionListItem(
        journal: j,
        accountName: 'Everyday',
        categoryLabel: world.nameFor(j.postings.first.ledgerAccountId),
        reviewed: false,
        hasReceipt: j == world.journals[1],
        unsynced: true,
      ),
  ];

  Future<_Log> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final log = _Log();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransactionList(
            items: items(),
            categories: world.chart.categories.toList(),
            onOpen: (j) => log.opened.add(j.id),
            onMarkReviewed: (ids) => log.reviewed.addAll(ids),
            onCategorise: (ids, category) => log.categorised[category] = ids,
          ),
        ),
      ),
    );
    return log;
  }

  testWidgets('phone rows show status in text and a visible review button', (
    tester,
  ) async {
    final log = await pump(tester, const Size(400, 900));
    expect(find.text('Fresh Grocer'), findsOneWidget);
    expect(find.text(r'-$450.00'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Not synced'), findsWidgets);
    expect(find.byTooltip('Receipt attached'), findsOneWidget);
    await tester.tap(find.byTooltip('Mark reviewed').first);
    expect(log.reviewed, hasLength(1));
  });

  testWidgets('desktop uses a dense table with multi-select bulk actions', (
    tester,
  ) async {
    final log = await pump(tester, const Size(1400, 900));
    expect(find.byType(DataTable), findsOneWidget);
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.tap(find.byType(Checkbox).at(3));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.text('Categorise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rent').last);
    await tester.pumpAndSettle();
    expect(log.categorised['rent'], hasLength(3));
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.tap(find.text('Mark reviewed'));
    expect(log.reviewed, hasLength(1));
  });

  testWidgets('search filters by payee, notes, amount and tags', (
    tester,
  ) async {
    await pump(tester, const Size(400, 900));
    await tester.enterText(find.byType(SearchBar), 'dining');
    await tester.pump();
    expect(find.text('Fresh Grocer'), findsNothing);
    await tester.enterText(find.byType(SearchBar), '450');
    await tester.pump();
    expect(find.text('Fresh Grocer'), findsOneWidget);
  });
}

class _Log {
  final opened = <String>[];
  final reviewed = <String>[];
  final categorised = <String, List<String>>{};
}
