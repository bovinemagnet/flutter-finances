import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/app/action_snack_bar.dart';
import 'package:finance_app/app/appearance.dart';
import 'package:finance_app/data/workspace_gate.dart';
import 'package:finance_app/main.dart' show FinanceApp;
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

class _NoKeyStore implements SecureKeyStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<Uint8List?> read(String name) async => null;
  @override
  Future<void> write(String name, Uint8List material) async {}
  @override
  Future<void> delete(String name) async {}
}

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));

  testWidgets('the app clears these messages when a page opens', (
    tester,
  ) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('action_snack_bar'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    await tester.pumpWidget(
      FinanceApp(
        services: testServices(),
        gate: WorkspaceGate(dir!, _NoKeyStore()),
        appearance: Appearance.inMemory(),
      ),
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.navigatorObservers, contains(isA<ActionSnackBarObserver>()));
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ActionSnackBarObserver()],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showActionSnackBar(
                ScaffoldMessenger.of(context),
                content: const Text('Saved'),
                label: 'Undo',
                onPressed: () {},
              ),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
  }

  testWidgets('goes away by itself', (tester) async {
    await show(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('waits for someone using a screen reader', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await show(tester);
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
  });

  group('when something else opens', () {
    void useScreenReader(WidgetTester tester) {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
    }

    NavigatorState navigator(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator));

    testWidgets('a new page clears a message kept for a screen reader', (
      tester,
    ) async {
      useScreenReader(tester);
      await show(tester);

      navigator(tester).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Next page')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Next page'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('a dialog leaves it there', (tester) async {
      useScreenReader(tester);
      await show(tester);

      showDialog<void>(
        context: navigator(tester).context,
        builder: (_) => const AlertDialog(content: Text('A question')),
      );
      await tester.pumpAndSettle();

      expect(find.text('A question'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('the next message in line still shows', (tester) async {
      useScreenReader(tester);
      await show(tester);
      ScaffoldMessenger.of(tester.element(find.text('Show')))
          .showSnackBar(const SnackBar(content: Text('Next message')));
      await tester.pump();

      navigator(tester).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Next page')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Undo'), findsNothing);
      expect(find.text('Next message'), findsOneWidget);
    });
  });
}
