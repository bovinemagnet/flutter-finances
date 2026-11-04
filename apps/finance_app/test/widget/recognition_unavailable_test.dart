import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/receipts/receipt_capture.dart';
import 'package:finance_app/features/receipts/receipt_review_screen.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

import '../support/test_services.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

/// A JPEG that passes validation but stops the decoder.
Uint8List _damagedJpeg() {
  final good = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 400, height: 600)),
  );
  var start = 2;
  while (!(good[start] == 0xFF && good[start + 1] == 0xC0)) {
    start++;
  }
  return Uint8List.fromList(good)..[start + 11] = 0;
}

CapturedFile _photo() => CapturedFile(
  Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
  source: CaptureSource.camera,
);

/// NFR 06: when text recognition is not installed the app says so, rather
/// than quietly leaving the receipt unread.
void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  late Directory dir;
  late AppState state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recognition');
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> openStore(WidgetTester tester) => tester.runAsync(() async {
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => LocalDate(2026, 10, 19));
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: testServices(),
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a damaged image says so instead of showing nothing', (
    tester,
  ) async {
    await openStore(tester);
    late String receiptId;
    await tester.runAsync(() async {
      receiptId = (await state.receipts.capture([
        CapturedFile(_damagedJpeg(), source: CaptureSource.fileImport),
      ])).id;
    });
    await pump(tester, ReceiptReviewScreen(receiptId: receiptId));
    await tester.runAsync(() => Future<void>.delayed(Durations.long2));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be shown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capturing says the receipt cannot be read here', (
    tester,
  ) async {
    await openStore(tester);
    await pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => saveCapturedReceipt(context, [_photo()]),
            child: const Text('Capture'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Capture'));
    await tester.runAsync(() => Future<void>.delayed(Durations.long2));
    await tester.pump();

    expect(
      find.text(
        'Receipt saved on this device. '
        '${UnavailableTextRecogniser().unavailableMessage}; '
        'enter the details when reviewing',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unread receipt explains why it was not read', (
    tester,
  ) async {
    await openStore(tester);
    late String receiptId;
    await tester.runAsync(() async {
      receiptId = (await state.receipts.capture([_photo()])).id;
    });
    await pump(tester, ReceiptReviewScreen(receiptId: receiptId));

    expect(
      find.text(UnavailableTextRecogniser().unavailableMessage),
      findsOneWidget,
    );
    expect(find.text('Enter the details by hand.'), findsOneWidget);
  });

  test('the desktop engine names what to install', () {
    expect(
      TesseractTextRecogniser().unavailableMessage,
      'Reading text needs Tesseract with English language data installed',
    );
  });
}
