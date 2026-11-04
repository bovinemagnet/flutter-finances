import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/receipt_service.dart';
import 'package:finance_app/data/reminders.dart';
import 'package:finance_app/platform/image_tools.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:finance_store/finance_store.dart' as store show VaultAssetKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

class _FakeRecogniser implements TextRecogniser {
  @override
  String get unavailableMessage => 'unavailable';

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

/// Recognition that waits for [hold], as a slow engine does.
class _HeldRecogniser implements TextRecogniser {
  final hold = Completer<void>();
  @override
  String get unavailableMessage => 'unavailable';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    await hold.future;
    return OcrResult.fromText(
      'TOTAL 13.50',
      engine: 'fake',
      engineVersion: '1',
    );
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
  setUpAll(() => initializeDateFormatting('en_AU'));
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

  test('an image the decoder cannot read is still kept', () async {
    final good = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 400, height: 600)),
    );
    var start = 2;
    while (!(good[start] == 0xFF && good[start + 1] == 0xC0)) {
      start++;
    }
    // A sampling factor of zero passes validation but stops the decoder.
    final bad = Uint8List.fromList(good)..[start + 11] = 0;
    final receipt = await state.receipts.capture([
      CapturedFile(bad, source: CaptureSource.fileImport),
    ]);
    expect(state.receipts.receipt(receipt.id), isNotNull);
    expect(state.receipts.pagesFor(receipt.id), hasLength(1));
  });

  /// A JPEG that passes validation but stops the decoder.
  Uint8List damagedPhoto() {
    final good = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 400, height: 600)),
    );
    var start = 2;
    while (!(good[start] == 0xFF && good[start + 1] == 0xC0)) {
      start++;
    }
    return Uint8List.fromList(good)..[start + 11] = 0;
  }

  test('a damaged image still gets its other warnings', () async {
    final bad = damagedPhoto();
    final first = await state.receipts.capture([
      CapturedFile(bad, source: CaptureSource.fileImport),
    ]);
    final second = await state.receipts.capture([
      CapturedFile(bad, source: CaptureSource.fileImport),
    ]);
    final warnings = await state.receipts.warningsFor(second.id);
    expect(warnings.map((w) => w.otherReceiptId), contains(first.id));
  });

  test('an image fingerprint does not share the id of its document', () async {
    final receipt = await state.receipts.capture([
      CapturedFile(photo(), source: CaptureSource.fileImport),
    ]);
    final assetId = state.receipts.pagesFor(receipt.id).single.sourceAssetId;
    expect(state.store.entity(ReceiptEntityTypes.fingerprint, assetId), isNull);
    expect(
      state.store.entity(
        ReceiptEntityTypes.fingerprint,
        ownedEntityId(ReceiptEntityTypes.fingerprint, assetId),
      ),
      isNotNull,
    );
  });

  group('reading a receipt again', () {
    late Receipt receipt;

    setUp(() async {
      receipt = await state.receipts.capture([
        CapturedFile(photo(), source: CaptureSource.fileImport),
      ]);
    });

    Future<void> leaveAs(ExtractionState extractionState) =>
        state.store.upsertEntity(
          ReceiptEntityTypes.receipt,
          receipt.id,
          receiptToJson(receipt.copyWith(extractionState: extractionState)),
        );

    test('finishes a read the app stopped part-way through', () async {
      await leaveAs(ExtractionState.extracting);
      expect(
        state.receipts.canReadAgain(state.receipts.receipt(receipt.id)!),
        isTrue,
      );
      final read = await state.receipts.extract(
        receipt.id,
        _FakeRecogniser(_receiptText),
      );
      expect(read.extractionState, ExtractionState.needsReview);
    });

    test('does not offer a read that is still running', () async {
      final recogniser = _HeldRecogniser();
      final reading = state.receipts.extract(receipt.id, recogniser);
      await Future<void>.delayed(Duration.zero);
      final current = state.receipts.receipt(receipt.id)!;
      expect(current.extractionState, ExtractionState.extracting);
      expect(state.receipts.canReadAgain(current), isFalse);
      recogniser.hold.complete();
      await reading;
    });

    test('offers a receipt that was never read', () async {
      expect(state.receipts.canReadAgain(receipt), isTrue);
    });

    test('does not offer a receipt whose document is elsewhere', () async {
      final other = Receipt(
        id: newId(),
        capturedAt: DateTime.utc(2026, 11, 4),
        source: CaptureSource.email,
      );
      expect(state.receipts.canReadAgain(other), isFalse);
    });

    test('cloud text is not offered while a read is running', () async {
      expect(state.receipts.canUseCloudText(receipt), isTrue);
      final recogniser = _HeldRecogniser();
      final reading = state.receipts.extract(receipt.id, recogniser);
      await Future<void>.delayed(Duration.zero);
      expect(
        state.receipts.canUseCloudText(state.receipts.receipt(receipt.id)!),
        isFalse,
      );
      recogniser.hold.complete();
      await reading;
      expect(
        state.receipts.canUseCloudText(state.receipts.receipt(receipt.id)!),
        isTrue,
      );
    });

    test('cloud text is not offered on a reviewed receipt', () async {
      final reviewed = await state.receipts.review(
        receipt.id,
        ReceiptFields(
          merchant: 'Fresh Grocer',
          date: today,
          total: Money(1350, aud),
        ),
        const KeepDocumentOnly(),
      );
      expect(state.receipts.canUseCloudText(reviewed), isFalse);
    });

    test('cloud text can replace a reading that needs review', () async {
      final first = await state.receipts.extract(
        receipt.id,
        _FakeRecogniser(_receiptText),
      );
      final second = await state.receipts.extractFromText(
        receipt.id,
        'TOTAL 20.00',
      );
      expect(second.extractionState, ExtractionState.needsReview);
      expect(second.latestExtractionId, isNot(first.latestExtractionId));
    });

    test('cloud text leaves a reviewed receipt as it is', () async {
      await state.receipts.review(
        receipt.id,
        ReceiptFields(
          merchant: 'Fresh Grocer',
          date: today,
          total: Money(1350, aud),
        ),
        const CreateExpense(accountId: 'bank', categoryId: 'groceries'),
      );
      final after = await state.receipts.extractFromText(
        receipt.id,
        'TOTAL 20.00',
      );
      expect(after.extractionState, ExtractionState.reviewed);
      expect(after.outcome, ReviewOutcome.expenseCreated);
    });
  });

  group('while a receipt is being read', () {
    late _HeldRecogniser recogniser;
    late Receipt receipt;
    late Future<Receipt> reading;

    setUp(() async {
      recogniser = _HeldRecogniser();
      receipt = await state.receipts.capture([
        CapturedFile(photo(), source: CaptureSource.fileImport),
      ]);
      reading = state.receipts.extract(receipt.id, recogniser);
      await Future<void>.delayed(Duration.zero);
    });

    ReceiptFields confirmed() => ReceiptFields(
      merchant: 'Fresh Grocer',
      date: today,
      total: Money(1350, aud),
    );

    test('a review stands when reading finishes later', () async {
      await state.receipts.review(
        receipt.id,
        confirmed(),
        const CreateExpense(accountId: 'bank', categoryId: 'groceries'),
      );
      recogniser.hold.complete();
      await reading;
      final after = state.receipts.receipt(receipt.id)!;
      expect(after.extractionState, ExtractionState.reviewed);
      expect(after.outcome, ReviewOutcome.expenseCreated);
      expect(after.confirmed.total, Money(1350, aud));
    });

    test('a deletion stands when reading finishes later', () async {
      await state.receipts.deleteDocument(receipt.id);
      recogniser.hold.complete();
      await reading;
      expect(state.receipts.receipts(), isEmpty);
      expect(state.store.entities(ReceiptEntityTypes.extraction), isEmpty);
    });

    test('with nothing else done, reading finishes as usual', () async {
      recogniser.hold.complete();
      await reading;
      final after = state.receipts.receipt(receipt.id)!;
      expect(after.extractionState, ExtractionState.needsReview);
      expect(after.latestExtractionId, isNotNull);
    });
  });

  group('capturing with a known id', () {
    const id = '11111111-1111-5111-8111-111111111111';

    test('makes one receipt however many times it runs', () async {
      final receipts = state.receipts;
      final first = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.email),
      ], receiptId: id);
      final second = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.email),
      ], receiptId: id);
      expect(first.id, id);
      expect(second.id, id);
      expect(receipts.receipts(), hasLength(1));
      expect(receipts.pagesFor(id), hasLength(1));
    });

    test('a retry after a partial capture does not duplicate pages', () async {
      final receipts = state.receipts;
      // The app stopped after writing a page, before the receipt itself.
      await state.store.upsertEntity(
        ReceiptEntityTypes.page,
        nameBasedId(id, 'page-1'),
        receiptPageToJson(
          ReceiptPage(
            id: nameBasedId(id, 'page-1'),
            receiptId: id,
            pageNumber: 1,
            sourceAssetId: 'interrupted',
            sourcePageIndex: 0,
          ),
        ),
      );
      await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.email),
      ], receiptId: id);
      expect(receipts.pagesFor(id), hasLength(1));
    });

    test('a retry reuses a document already saved', () async {
      final receipts = state.receipts;
      final asset = await state.store.vault.saveAsset(
        ownerType: ReceiptEntityTypes.receipt,
        ownerId: id,
        kind: store.VaultAssetKind.source,
        contentType: 'image/jpeg',
        bytes: photo(),
        assetId: nameBasedId(id, 'asset-0'),
      );
      await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.email),
      ], receiptId: id);
      expect(receipts.pagesFor(id).single.sourceAssetId, asset.id);
    });

    test('two devices derive the same pages and documents', () async {
      await state.receipts.capture([
        CapturedFile(photo(), source: CaptureSource.email),
      ], receiptId: id);
      final page = state.receipts.pagesFor(id).single;
      expect(page.id, nameBasedId(id, 'page-1'));
      expect(page.sourceAssetId, nameBasedId(id, 'asset-0'));
    });

    test('uses the time it is given', () async {
      final at = DateTime.utc(2026, 10, 1, 9);
      final receipt = await state.receipts.capture(
        [CapturedFile(photo(), source: CaptureSource.email)],
        receiptId: id,
        capturedAt: at,
      );
      expect(receipt.capturedAt, at);
    });

    test('dates the document by that time, as every device will', () async {
      final at = DateTime.utc(2026, 10, 1, 9);
      await state.receipts.capture(
        [CapturedFile(photo(), source: CaptureSource.email)],
        receiptId: id,
        capturedAt: at,
      );
      final page = state.receipts.pagesFor(id).single;
      expect(state.store.vault.asset(page.sourceAssetId)!.createdAt, at);
    });
  });

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

  // NFR 04 allows 5 s for a clean single page, recognition included. The
  // engine runs on the device and cannot be timed here; everything after
  // it (parsing, items, saving the proposal, indexing) must leave most of
  // that time to the engine.
  test('NFR 04: p95 proposal after recognition is under 1 s', () async {
    final recogniser = _FakeRecogniser(_receiptText);
    final times = <Duration>[];
    for (var i = 0; i < 20; i++) {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      final sw = Stopwatch()..start();
      final read = await receipts.extract(receipt.id, recogniser);
      times.add(sw.elapsed);
      expect(read.extractionState, ExtractionState.needsReview);
    }
    times.sort();
    final p95 = times[(times.length * 95 / 100).ceil() - 1];
    // ignore: avoid_print
    print('NFR 04 p95 proposal after recognition: ${p95.inMilliseconds} ms');
    expect(p95, lessThan(const Duration(seconds: 1)));
  });

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

  test('cloud text is parsed into the same reviewable proposal', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    final extracted = await receipts.extractFromText(receipt.id, _receiptText);
    expect(extracted.extractionState, ExtractionState.needsReview);
    final extraction = receipts.extractionFor(extracted)!;
    expect(extraction.suggested.total, Money(1350, aud));
    expect(extraction.ocr.engine, 'cloud');
  });

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

  test(
    'the date convention setting decides ambiguous receipt dates (OCR 04)',
    () async {
      const text = 'CORNER STORE\n03/04/2026\nTOTAL 9.90\n';
      final first = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.extract(first.id, _FakeRecogniser(text));
      expect(
        receipts.extractionFor(receipts.receipt(first.id)!)!.suggested.date,
        LocalDate(2026, 4, 3),
      );
      await state.setDateConvention(DateConvention.monthDay);
      final second = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.extract(second.id, _FakeRecogniser(text));
      expect(
        receipts.extractionFor(receipts.receipt(second.id)!)!.suggested.date,
        LocalDate(2026, 3, 4),
      );
    },
  );

  test(
    'extraction keeps line items and warranties produce reminders',
    () async {
      final receipt = await receipts.capture([
        CapturedFile(photo(), source: CaptureSource.camera),
      ]);
      await receipts.extract(receipt.id, _FakeRecogniser(_receiptText));
      final items = receipts.itemsFor(receipt.id)!;
      expect(
        items.items.map((i) => i.description),
        containsAll(['Bananas 1kg', 'Milk 2L', 'Bread']),
      );
      expect(items.reconciliation, ItemReconciliation.consistent);

      await receipts.addWarranty(
        Warranty(
          id: newId(),
          receiptId: receipt.id,
          description: 'Kettle',
          startDate: today,
          months: 12,
        ),
      );
      expect(receipts.warranties().single.expiresOn, LocalDate(2027, 10, 18));
      final reminders = planReminders(
        const [],
        const [],
        warranties: receipts.warranties(),
        now: DateTime(2027, 9, 1),
        horizonDays: 60,
      );
      expect(reminders.single.title, 'Warranty ending');
      expect(reminders.single.privateBody, isNot(contains('Kettle')));
    },
  );

  test('a multi-receipt capture gets a suggested split to confirm', () async {
    final receipt = await receipts.capture([
      CapturedFile(photo(), source: CaptureSource.camera),
      CapturedFile(photo(), source: CaptureSource.camera),
    ]);
    final texts = [
      'CORNER CAFE\n19/10/2026\nFlat white 5.00\nTOTAL 5.00\n',
      'FRESH GROCER PTY LTD\n18/10/2026\nMilk 3.80\nTOTAL 3.80\n',
    ];
    var call = 0;
    final proposal = await receipts.suggestSeparation(
      receipt.id,
      _PerPageRecogniser(() => texts[call++]),
    );
    expect(proposal.groups, hasLength(2));
    final created = await receipts.applySeparation(receipt.id, proposal);
    expect(created, hasLength(1));
    expect(receipts.receipts(), hasLength(2));
  });
}

class _PerPageRecogniser implements TextRecogniser {
  @override
  String get unavailableMessage => 'unavailable';

  _PerPageRecogniser(this.next);
  final String Function() next;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<OcrResult> recognise(List<Uint8List> images) async =>
      OcrResult.fromText(next(), engine: 'fake', engineVersion: '1');
}
