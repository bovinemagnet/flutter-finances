import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/workspace_gate.dart';
import 'package:finance_app/screens/startup_screen.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

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

  for (final width in [360.0, 411.0, 800.0]) {
    testWidgets('first-run actions stay clear of the title at $width wide', (
      tester,
    ) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('startup'),
      );
      addTearDown(() => dir!.delete(recursive: true));
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: StartupScreen(
            gate: WorkspaceGate(dir!, _NoKeyStore()),
            onReady: (_, {sync}) {},
            createSync: (_) => throw UnimplementedError(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text('Set up your finances'));
      for (final label in ['Use my synced data', 'Restore from a backup']) {
        final action = find.widgetWithText(TextButton, label);
        expect(tester.getRect(action).overlaps(title), isFalse, reason: label);
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
      }
    });
  }
}
