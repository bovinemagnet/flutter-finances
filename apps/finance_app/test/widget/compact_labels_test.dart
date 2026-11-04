import 'package:finance_app/app/shell.dart';
import 'package:finance_app/app/theme.dart';
import 'package:finance_app/features/transactions/transaction_form.dart';
import 'package:finance_app/features/transactions/transaction_form_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// These measure real text, so they use the bundled font rather than the test
/// font, whose square glyphs would wrap every label.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('en_AU');
    final loader = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'));
    await loader.load();
  });

  int lines(WidgetTester tester, String text) {
    final paragraph = tester.renderObject<RenderParagraph>(find.text(text).last);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    return {for (final box in boxes) box.top}.length;
  }

  Future<void> pump(WidgetTester tester, Size size, Widget home) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.1)),
          child: child!,
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  // The narrowest common phone, and the phone the wrapping was seen on.
  for (final width in [360.0, 411.0]) {
    testWidgets('navigation labels stay on one line at $width wide', (
      tester,
    ) async {
      await pump(
        tester,
        Size(width, 800),
        AdaptiveShell(
          selected: Destination.transactions,
          onSelect: (_) {},
          onAdd: (_) {},
          body: const SizedBox(),
        ),
      );
      for (final label in [
        'Overview',
        'Entries',
        'Budget',
        'Receipts',
        'Plan',
      ]) {
        expect(lines(tester, label), 1, reason: label);
      }
      // The page keeps its full name.
      expect(find.widgetWithText(AppBar, 'Transactions'), findsOneWidget);
    });

    testWidgets('entry types stay on one line at $width wide', (tester) async {
      final model = TransactionFormModel(
        Chart(currency: Currency.aud, accounts: const [], categories: const []),
        today: LocalDate(2026, 11, 4),
      );
      await pump(
        tester,
        Size(width, 800),
        Scaffold(
          body: TransactionForm(model: model, onSave: (_) async {}),
        ),
      );
      for (final label in ['Expense', 'Income', 'Transfer', 'Refund']) {
        expect(lines(tester, label), 1, reason: label);
      }
    });
  }

  testWidgets('with no accounts the entry form says how to add one', (
    tester,
  ) async {
    final model = TransactionFormModel(
      Chart(currency: Currency.aud, accounts: const [], categories: const []),
      today: LocalDate(2026, 11, 4),
    );
    await pump(
      tester,
      const Size(411, 800),
      Scaffold(
        body: TransactionForm(model: model, onSave: (_) async {}),
      ),
    );
    expect(find.textContaining('Add an account first'), findsOneWidget);
  });
}
