import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipt_review_screen.dart';
import 'package:finance_app/platform/pdf_reader.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

import '../support/pdf_fixtures.dart';
import '../support/test_services.dart';

class _Reader implements PdfReader {
  @override
  Future<List<String>> pageText(Uint8List pdf, {required int maxPages}) async =>
      ['CORNER GROCER PTY LTD\n12/10/2026\nGST INCLUDED 0.00\nTOTAL 15.50'];

  @override
  Future<Uint8List> renderPage(Uint8List pdf, int pageIndex) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async => dir = await Directory.systemTemp.createTemp('pdf-review'));
  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<String> open(WidgetTester tester, CapturedFile file) async {
    late String receiptId;
    await tester.runAsync(() async {
      final store = await FinanceStore.create(
        dir,
        keyProtection: KeyProtection.password(
          'secret',
          kdf: const Argon2idParameters(
            memoryKiB: 64,
            iterations: 1,
            parallelism: 1,
          ),
        ),
      );
      state = AppState(store, today: () => LocalDate(2026, 11, 5));
      final receipt = await state.receipts.capture([file]);
      receiptId = receipt.id;
      await state.receipts.extract(
        receiptId,
        UnavailableTextRecogniser(),
        pdfReader: _Reader(),
      );
    });
    tester.view.physicalSize = const Size(402, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(home: ReceiptReviewScreen(receiptId: receiptId)),
      ),
    );
    await tester.pumpAndSettle();
    return receiptId;
  }

  CapturedFile pdf() => CapturedFile(
    textPdf([
      ['receipt'],
    ]),
    source: CaptureSource.fileImport,
  );

  testWidgets('a PDF shows what was read for checking', (tester) async {
    await open(tester, pdf());
    expect(
      find.widgetWithText(TextField, 'CORNER GROCER PTY LTD'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, '15.50'), findsOneWidget);
  });

  testWidgets('a PDF is not offered image editing it cannot use', (
    tester,
  ) async {
    await open(tester, pdf());
    expect(find.text('Improve readability'), findsNothing);
  });

  testWidgets('a photo is still offered image editing', (tester) async {
    await open(
      tester,
      CapturedFile(
        Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 600))),
        source: CaptureSource.fileImport,
      ),
    );
    expect(find.text('Improve readability'), findsOneWidget);
  });

  testWidgets('a field to check never ends in an empty reason', (tester) async {
    await open(tester, pdf());
    final endingBare = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data ?? '').startsWith('Check the') &&
          (w.data ?? '').trimRight().endsWith(':'),
    );
    expect(endingBare, findsNothing);
  });
}
