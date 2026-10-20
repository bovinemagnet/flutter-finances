import 'package:finance_app/app/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('choosing dark switches the app and shows the choice', (
    tester,
  ) async {
    final appearance = Appearance.inMemory();
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: appearance,
        builder: (context, mode, _) => MaterialApp(
          themeMode: mode,
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(body: AppearanceTile(appearance: appearance)),
        ),
      ),
    );
    expect(find.text('Follows this device'), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appearance.value, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(AppearanceTile))).brightness,
      Brightness.dark,
    );
    expect(find.text('Always dark'), findsOneWidget);

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(appearance.value, ThemeMode.system);
  });
}
