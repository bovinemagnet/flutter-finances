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

/// Draws any page as a small image, and remembers which it was asked for.
class _DrawingReader implements PdfReader {
  _DrawingReader({this.fails = false});
  final bool fails;
  final drawn = <int>[];

  @override
  Future<List<String>> pageText(Uint8List pdf, {required int maxPages}) async =>
      const [];

  @override
  Future<Uint8List> renderPage(Uint8List pdf, int pageIndex) async {
    drawn.add(pageIndex);
    if (fails) throw const PdfReadException('This PDF could not be read');
    return Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 60)));
  }
}

AppServices _withPdfReader(PdfReader? reader) {
  final base = testServices();
  return AppServices(
    capabilities: base.capabilities,
    scanner: base.scanner,
    fileImporter: base.fileImporter,
    fileExporter: base.fileExporter,
    shareInbox: base.shareInbox,
    notifications: base.notifications,
    textRecogniser: base.textRecogniser,
    workspaceDirectory: base.workspaceDirectory,
    authenticator: base.authenticator,
    pdfReader: reader,
  );
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

  Future<String> open(
    WidgetTester tester,
    CapturedFile file, {
    PdfReader? previewReader,
  }) async {
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
        services: _withPdfReader(previewReader),
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

  group('the PDF page', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Durations.long2));
      await tester.pumpAndSettle();
    }

    testWidgets('is shown for checking against', (tester) async {
      final reader = _DrawingReader();
      await open(tester, pdf(), previewReader: reader);
      await settle(tester);
      expect(reader.drawn, [0]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('PDF receipt, page 1'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Receipt image, page 1')),
        findsOneWidget,
      );
    });

    testWidgets('draws each page of a longer PDF', (tester) async {
      final reader = _DrawingReader();
      await open(
        tester,
        CapturedFile(
          textPdf([
            ['one'],
            ['two'],
          ]),
          source: CaptureSource.fileImport,
        ),
        previewReader: reader,
      );
      await settle(tester);
      expect(reader.drawn.first, 0);
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await settle(tester);
      expect(reader.drawn, contains(1));
    });

    testWidgets('is drawn once, however often the screen rebuilds', (
      tester,
    ) async {
      final reader = _DrawingReader();
      await open(tester, pdf(), previewReader: reader);
      await settle(tester);
      await tester.runAsync(() async => state.refresh());
      await settle(tester);
      expect(reader.drawn, [0]);
    });

    testWidgets('falls back to an icon when it cannot be drawn', (
      tester,
    ) async {
      await open(tester, pdf(), previewReader: _DrawingReader(fails: true));
      await settle(tester);
      expect(find.text('PDF receipt, page 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to an icon with no PDF engine', (tester) async {
      await open(tester, pdf());
      await settle(tester);
      expect(find.text('PDF receipt, page 1'), findsOneWidget);
    });
  });

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
