import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/receipt_service.dart';
import 'package:finance_app/platform/image_tools.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

class _FakeRecogniser implements TextRecogniser {
  _FakeRecogniser(this.text);
  final String? text;
  @override
  Future<bool> isAvailable() async => text != null;
  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    if (text == null) throw const TextRecognitionException('unavailable');
    return OcrResult.fromText(text!, engine: 'fake', engineVersion: '1');
  }
}

const _receiptText = '''
FRESH GROCER PTY LTD
ABN 12 345 678 901
19/10/2026 10:42
Bananas 1kg      4.50
Milk 2L          3.80
Bread            5.20
SUBTOTAL        13.50
GST INCLUDED     0.00
TOTAL           13.50
CASH            20.00
CHANGE           6.50
''';

void main() {
  const aud = Currency.aud;
  final today = LocalDate(2026, 10, 19);
  late Directory dir;
  late AppState state;
  late ReceiptService receipts;

  Uint8List photo() {
    final image = img.Image(width: 8, height: 8);
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(27, 1);
    return img.encodeJpg(image);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('receipts_test');
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => today);
    await store.createAccount(
      const Account(
        id: 'bank',
        name: 'Everyday',
        type: AccountType.transaction,
      ),
    );
    await store.createAccount(
      const Account(id: 'cash', name: 'Wallet', type: AccountType.cash),
    );
    await store.createCategory(
      const Category(
        id: 'groceries',
        name: 'Groceries',
        kind: CategoryKind.expense,
      ),
    );
    state.refresh();
    receipts = ReceiptService(state);
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  test(
    'a captured photo is stored before success, without location data',
    () async {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      expect(receipts.receipts().single.id, receipt.id);
      expect(receipt.extractionState, ExtractionState.captured);
      final page = receipts.pagesFor(receipt.id).single;
      final bytes = await state.store.vault.readAsset(page.sourceAssetId);
      expect(img.decodeJpg(bytes)!.exif.gpsIfd.isEmpty, isTrue);
    },
  );

  test('unsupported files are rejected with an actionable message', () async {
    await expectLater(
      receipts.capture([CapturedFile(Uint8List.fromList('hello'.codeUnits))]),
      throwsA(
        isA<ReceiptRejectedException>().having(
          (e) => e.messages.single,
          'message',
          isNotEmpty,
        ),
      ),
    );
    expect(receipts.receipts(), isEmpty);
  });

  test(
    'extraction proposes fields without overwriting confirmed values (A06)',
    () async {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      final extracted = await receipts.extract(
        receipt.id,
        _FakeRecogniser(_receiptText),
      );
      expect(extracted.extractionState, ExtractionState.needsReview);
      final extraction = receipts.extractionFor(extracted)!;
      expect(extraction.suggested.total, Money(1350, aud));
      expect(extraction.suggested.date, today);
    },
  );

  test('failed extraction keeps the document and allows retry', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    final failed = await receipts.extract(receipt.id, _FakeRecogniser(null));
    expect(failed.extractionState, ExtractionState.extractionFailed);
    expect(receipts.pagesFor(receipt.id), hasLength(1));
    final retried = await receipts.extract(
      receipt.id,
      _FakeRecogniser(_receiptText),
    );
    expect(retried.extractionState, ExtractionState.needsReview);
  });

  test(
    'attaching to an existing transaction changes no balance (A07)',
    () async {
      final journal = await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(1350, aud),
          effectiveDate: today,
          splits: [Split('groceries', Money(1350, aud))],
        ),
      );
      final before = state.ledger.displayBalance('bank');
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.review(
        receipt.id,
        ReceiptFields(
          total: Money(1350, aud),
          date: today,
          merchant: 'Fresh Grocer',
        ),
        AttachToTransaction(journal),
      );
      expect(state.ledger.displayBalance('bank'), before);
      expect(state.ledger.journals, hasLength(1));
      expect(receipts.receiptJournalIds, {journal.id});
    },
  );

  test(
    'creating an expense posts only after confirmation and links it',
    () async {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.review(
        receipt.id,
        ReceiptFields(
          total: Money(1350, aud),
          date: today,
          merchant: 'Fresh Grocer',
        ),
        const CreateExpense(accountId: 'bank', categoryId: 'groceries'),
      );
      expect(state.ledger.displayBalance('bank'), Money(-1350, aud));
      expect(receipts.receiptJournalIds, hasLength(1));
      expect(
        receipts.receipts().single.extractionState,
        ExtractionState.reviewed,
      );
    },
  );

  test('deleting the document keeps the transaction', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    await receipts.review(
      receipt.id,
      ReceiptFields(total: Money(1350, aud), date: today),
      const CreateExpense(accountId: 'bank', categoryId: 'groceries'),
    );
    await receipts.deleteDocument(receipt.id);
    expect(receipts.receipts(), isEmpty);
    expect(state.ledger.displayBalance('bank'), Money(-1350, aud));
  });

  test(
    'search finds receipts by extracted text and filters unmatched',
    () async {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.extract(receipt.id, _FakeRecogniser(_receiptText));
      expect(
        receipts.search(const ReceiptQuery(text: 'bananas')),
        hasLength(1),
      );
      expect(
        receipts.search(const ReceiptQuery(unmatchedOnly: true)),
        hasLength(1),
      );
      expect(receipts.search(const ReceiptQuery(text: 'petrol')), isEmpty);
    },
  );

  test('warns about the same file saved twice without blocking it', () async {
    final bytes = photo();
    final first = await receipts.capture([
      CapturedFile(bytes, source: CaptureSource.fileImport),
    ]);
    final second = await receipts.capture([
      CapturedFile(bytes, source: CaptureSource.fileImport),
    ]);
    final warnings = await receipts.warningsFor(second.id);
    expect(warnings.map((w) => w.otherReceiptId), contains(first.id));
    expect(receipts.receipts(), hasLength(2));
  });

  test('a readable copy is saved beside the untouched original', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    final page = receipts.pagesFor(receipt.id).single;
    final original = await state.store.vault.readAsset(page.sourceAssetId);
    await receipts.saveReadableCopy(
      page,
      const ImageEdits(quarterTurns: 1, enhanceContrast: true),
    );
    final updated = receipts.pagesFor(receipt.id).single;
    expect(updated.derivativeAssetId, isNotNull);
    expect(await state.store.vault.readAsset(updated.sourceAssetId), original);
  });

  test('a multi-receipt document can be split by page (REC 05)', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
      CapturedFile(photo(), source: CaptureSource.camera),
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    final created = await receipts.splitPages(receipt.id, [
      [1, 3],
      [2],
    ]);
    expect(receipts.pagesFor(receipt.id).map((p) => p.pageNumber), [1, 2]);
    expect(receipts.pagesFor(created.single.id), hasLength(1));
    expect(receipts.receipts(), hasLength(2));
  });

  test('receipts export as original files with a manifest (EXP 01)', () async {
    final bytes = photo();
    final receipt = await receipts.capture([
      CapturedFile(bytes, source: CaptureSource.fileImport),
    ]);
    final out = Directory('${dir.path}/export');
    expect(await receipts.exportOriginals(out), 1);
    final manifest = jsonDecode(
      File('${out.path}/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final entry = (manifest['receipts'] as List).single as Map<String, dynamic>;
    expect(entry['receiptId'], receipt.id);
    final file = (entry['files'] as List).single as Map<String, dynamic>;
    expect(File('${out.path}/${file['file']}').readAsBytesSync(), bytes);
  });
}
