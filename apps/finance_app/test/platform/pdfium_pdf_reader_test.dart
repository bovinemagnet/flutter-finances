import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/platform/adapters/pdfium_pdf_reader.dart';
import 'package:finance_app/platform/pdf_reader.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../support/pdf_fixtures.dart';

/// Runs the real PDF engine, unlike the tests of the code that uses it.
void main() {
  final reader = PdfiumPdfReader(cacheDirectory: Directory.systemTemp.path);

  // `flutter test` builds the engine here but does not load it by itself. An
  // app gets it from its own packaging.
  setUpAll(() {
    Pdfrx.pdfiumModulePath = Directory('build/native_assets')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) => f.uri.pathSegments.last.contains('pdfium.'))
        .absolute
        .path;
  });

  test('reads the text of each page', () async {
    final pages = await reader.pageText(
      textPdf([
        ['FRESH GROCER PTY LTD', 'TOTAL 13.50'],
        ['Thank you'],
      ]),
      maxPages: 10,
    );
    expect(pages, hasLength(2));
    expect(pages[0], contains('FRESH GROCER PTY LTD'));
    expect(pages[0], contains('TOTAL 13.50'));
    expect(pages[1], contains('Thank you'));
  });

  test('keeps each printed line as its own line', () async {
    final pages = await reader.pageText(
      textPdf([
        ['Milk 2L 3.80', 'Bread 5.20'],
      ]),
      maxPages: 10,
    );
    final lines = pages.single
        .split(RegExp(r'[\r\n]+'))
        .where((l) => l.trim().isNotEmpty);
    expect(lines, hasLength(2));
  });

  test('stops at the page limit', () async {
    final pages = await reader.pageText(
      textPdf([
        ['one'],
        ['two'],
        ['three'],
      ]),
      maxPages: 2,
    );
    expect(pages, hasLength(2));
  });

  test('a scanned page has no text', () async {
    final pages = await reader.pageText(scannedPdf(), maxPages: 10);
    expect(pages.single.trim(), isEmpty);
  });

  test('draws a scanned page as an image with its content', () async {
    final bytes = await reader.renderPage(scannedPdf(), 0);
    final image = img.decodeJpg(bytes)!;
    // A4 at 200 dots per inch.
    expect(image.width, closeTo(1653, 2));
    expect(image.height, closeTo(2339, 2));
    final middle = image.getPixel(image.width ~/ 2, image.height ~/ 2);
    expect(middle.r, greaterThan(150));
    expect(middle.g, lessThan(90));
  });

  test('a real PDF receipt ends up with suggested details', () async {
    final dir = await Directory.systemTemp.createTemp('pdf-receipt');
    addTearDown(() => dir.delete(recursive: true));
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
    addTearDown(store.close);
    final state = AppState(store, today: () => LocalDate(2026, 11, 5));
    final receipt = await state.receipts.capture([
      CapturedFile(
        textPdf([
          [
            'FRESH GROCER PTY LTD',
            '19/10/2026 10:42',
            'Bananas 1kg      4.50',
            'Milk 2L          3.80',
            'Bread            5.20',
            'TOTAL           13.50',
          ],
        ]),
        source: CaptureSource.email,
      ),
    ]);
    final read = await state.receipts.extract(
      receipt.id,
      UnavailableTextRecogniser(),
      pdfReader: reader,
    );
    expect(read.extractionState, ExtractionState.needsReview);
    final suggested = state.receipts.extractionFor(read)!.suggested;
    expect(suggested.total, Money(1350, Currency.aud));
    expect(suggested.merchant, contains('FRESH GROCER'));
    expect(suggested.date, LocalDate(2026, 10, 19));
    expect(state.ledger.journals, isEmpty);
  });

  test('a damaged file is reported, not thrown as something else', () async {
    await expectLater(
      reader.pageText(
        Uint8List.fromList('%PDF-1.7\nnot really a pdf'.codeUnits),
        maxPages: 10,
      ),
      throwsA(isA<PdfReadException>()),
    );
  });
}
