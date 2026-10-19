import 'package:finance_app/app/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<({List<Destination> selected, List<AddAction> added})> pump(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selected = <Destination>[];
    final added = <AddAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(
          selected: Destination.overview,
          onSelect: selected.add,
          onAdd: added.add,
          body: const Text('body'),
        ),
      ),
    );
    return (selected: selected, added: added);
  }

  testWidgets('compact width uses bottom navigation and a scan action', (
    tester,
  ) async {
    final log = await pump(tester, const Size(390, 844));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.text('Scan receipt'));
    expect(log.added, [AddAction.receipt]);
    await tester.tap(find.text('Budget'));
    expect(log.selected, [Destination.budget]);
  });

  testWidgets('medium width uses a navigation rail of primary destinations', (
    tester,
  ) async {
    await pump(tester, const Size(800, 1000));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Reports'), findsNothing);
  });

  testWidgets('expanded width shows the sidebar with secondary destinations', (
    tester,
  ) async {
    final log = await pump(tester, const Size(1280, 800));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    expect(log.added, [AddAction.transfer]);
  });

  testWidgets('keyboard shortcuts navigate and add', (tester) async {
    final log = await pump(tester, const Size(1280, 800));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    expect(log.selected, [Destination.budget]);
    expect(log.added, [AddAction.expense]);
  });

  testWidgets('every navigation control has a semantic label at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: AdaptiveShell(
            selected: Destination.overview,
            onSelect: (_) {},
            onAdd: (_) {},
            body: const Text('body'),
          ),
        ),
      ),
    );
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });
}
