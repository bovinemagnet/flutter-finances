import 'dart:async';
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

/// Recognition that waits for [hold], as a slow engine does.
class _HeldRecogniser implements TextRecogniser {
  final hold = Completer<void>();
  var started = 0;
  @override
  String get unavailableMessage => 'unavailable';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    started++;
    await hold.future;
    return OcrResult.fromText('TOTAL 1.00', engine: 'fake', engineVersion: '1');
  }
}

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

  testWidgets('a receipt deleted while it was read gets no reading message', (
    tester,
  ) async {
    await openStore(tester);
    final recogniser = _HeldRecogniser();
    final base = testServices();
    await tester.pumpWidget(
      AppScope(
        state: state,
        services: AppServices(
          capabilities: base.capabilities,
          scanner: base.scanner,
          fileImporter: base.fileImporter,
          shareInbox: base.shareInbox,
          notifications: base.notifications,
          textRecogniser: recogniser,
          workspaceDirectory: base.workspaceDirectory,
          authenticator: base.authenticator,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => saveCapturedReceipt(context, [_photo()]),
                child: const Text('Capture'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Capture'));
    await tester.runAsync(() async {
      while (recogniser.started == 0) {
        await Future<void>.delayed(Durations.short1);
      }
      await state.receipts.deleteDocument(state.receipts.receipts().single.id);
      recogniser.hold.complete();
      await Future<void>.delayed(Durations.medium1);
    });
    // Messages queue, so let "Receipt saved" finish before looking for another.
    var sawNoOther = true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      sawNoOther &=
          find.textContaining('could not be read').evaluate().isEmpty &&
          find.text('Receipt read; ready to review').evaluate().isEmpty;
    }
    expect(sawNoOther, isTrue);
  });

  testWidgets('a read that did not finish offers trying again', (tester) async {
    await openStore(tester);
    late String receiptId;
    await tester.runAsync(() async {
      final receipt = await state.receipts.capture([_photo()]);
      receiptId = receipt.id;
      await state.store.upsertEntity(
        'receipt',
        receipt.id,
        receiptToJson(
          receipt.copyWith(extractionState: ExtractionState.extracting),
        ),
      );
      state.refresh();
    });
    await pump(tester, ReceiptReviewScreen(receiptId: receiptId));
    expect(find.text('This receipt was not finished being read'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

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
    expect(find.textContaining('damaged'), findsNothing);
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
