import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

/// Encodes to a JSON string and back, as the store and server will.
Map<String, Object?> wire(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  test('receipts round-trip with confirmed fields in camelCase', () {
    final receipt = Receipt(
      id: 'r1',
      capturedAt: DateTime.utc(2026, 7, 1, 2, 3, 4),
      source: CaptureSource.shareTarget,
      extractionState: ExtractionState.needsReview,
      confirmed: ReceiptFields(
        merchant: 'Grocer',
        date: d('2026-07-01'),
        total: m('63.25'),
        tax: m('5.75'),
        isRefund: false,
      ),
      latestExtractionId: 'x1',
      outcome: ReviewOutcome.attachedToTransaction,
      notes: 'Weekly shop',
      tags: {'b', 'a'},
      deletedAt: DateTime.utc(2026, 8, 1),
    );
    final json = receiptToJson(receipt);
    expect(json['capturedAt'], '2026-07-01T02:03:04.000Z');
    expect(json['extractionState'], 'needsReview');
    expect(json['tags'], ['a', 'b']);
    expect(json['confirmed'], {
      'merchant': 'Grocer',
      'date': '2026-07-01',
      'totalMinor': 6325,
      'taxMinor': 575,
      'currency': 'AUD',
      'currencyExponent': 2,
      'isRefund': false,
    });
    expect(receiptToJson(receiptFromJson(wire(json))), json);

    final bare = Receipt(
      id: 'r2',
      capturedAt: DateTime.utc(2026),
      source: CaptureSource.camera,
    );
    expect(
      receiptToJson(receiptFromJson(wire(receiptToJson(bare)))),
      receiptToJson(bare),
    );
  });

  test('pages, assets and links round-trip', () {
    const page = ReceiptPage(
      id: 'p1',
      receiptId: 'r1',
      pageNumber: 2,
      sourceAssetId: 'a1',
      sourcePageIndex: 1,
      derivativeAssetId: 'a2',
    );
    final pageJson = receiptPageToJson(page);
    expect(receiptPageToJson(receiptPageFromJson(wire(pageJson))), pageJson);

    final asset = DocumentAsset(
      id: 'a1',
      receiptId: 'r1',
      kind: AssetKind.readableDerivative,
      contentType: DocumentContentType.pdf,
      sha256: 'ab' * 32,
      sizeBytes: 2048,
      pageCount: 3,
      createdAt: DateTime.utc(2026, 7, 1),
      presentLocally: false,
      uploadState: UploadState.uploaded,
      cloudCopyConfirmed: true,
    );
    final assetJson = documentAssetToJson(asset);
    expect(assetJson['contentType'], 'application/pdf');
    expect(assetJson['kind'], 'readableDerivative');
    expect(
      documentAssetToJson(documentAssetFromJson(wire(assetJson))),
      assetJson,
    );
    expect(
      documentAssetToJson(
        asset,
        includeLocalState: false,
      ).containsKey('presentLocally'),
      isFalse,
    );

    final link = ReceiptTransactionLink(
      id: 'l1',
      receiptId: 'r1',
      journalId: 'j1',
      allocated: m('63.25'),
      confirmedAt: DateTime.utc(2026, 7, 2),
    );
    final linkJson = receiptLinkToJson(link);
    expect(linkJson['allocatedMinor'], 6325);
    expect(
      receiptLinkToJson(receiptLinkFromJson(wire(linkJson), aud)),
      linkJson,
    );
    expect(
      () => receiptLinkFromJson(wire(linkJson), const Currency('USD', 2)),
      throwsA(isA<CurrencyMismatchException>()),
    );
  });

  test('extractions keep the original OCR output and every candidate', () {
    final ocr = OcrResult(
      engine: 'mlkit',
      engineVersion: '16.0.1',
      lines: const [
        OcrLine('SHOP', box: BoundingBox(1, 2, 3, 4), engineConfidence: 0.5),
        OcrLine('03/07/2026'),
        OcrLine('SUBTOTAL 50.00'),
        OcrLine('TOTAL US\$45.00'),
        OcrLine('GST 4.09'),
        OcrLine('CASH 50.00'),
        OcrLine('CHANGE 5.00'),
      ],
    );
    final extraction = parseReceipt(
      ocr,
      id: 'x1',
      receiptId: 'r1',
      createdAt: DateTime.utc(2026, 7, 2),
    );
    final json = extractionToJson(extraction);
    expect(json['extractionVersion'], receiptParserVersion);
    expect((json['ocr'] as Map)['engineVersion'], '16.0.1');
    expect((json['total'] as List).first, containsPair('valueMinor', 4500));
    expect((json['total'] as List).first, containsPair('currency', 'USD'));
    expect((json['date'] as List).first, containsPair('value', '2026-07-03'));
    expect(json['reviewReasons'], contains('AMBIGUOUS_DATE'));
    final back = extractionFromJson(wire(json));
    expect(extractionToJson(back), json);
    expect(back.ocr.lines.first.box, const BoundingBox(1, 2, 3, 4));
    expect(back.total.first.value, Money(4500, const Currency('USD', 2)));
  });

  test('import batches and source records round-trip', () {
    final batch = ImportBatch(
      id: 'b1',
      accountId: 'bank',
      sourceHash: 'cd' * 32,
      importedAt: DateTime.utc(2026, 7, 10),
      rowCount: 4,
      errorCount: 1,
      mappingId: 'm1',
      fileName: 'july.csv',
    ).rolledBack(DateTime.utc(2026, 7, 11));
    final batchJson = importBatchToJson(batch);
    expect(batchJson['status'], 'rolledBack');
    expect(importBatchToJson(importBatchFromJson(wire(batchJson))), batchJson);

    final record = SourceRecord(
      id: 's1',
      batchId: 'b1',
      accountId: 'bank',
      rowNumber: 2,
      fingerprint: 'fp|bank|2026-07-01|-6325|woolworths#1',
      raw: const ['01/07/2026', 'WOOLWORTHS', '-63.25', ''],
      date: d('2026-07-01'),
      amount: m('-63.25'),
      description: 'WOOLWORTHS',
      reference: 'R1',
      pendingReference: 'P1',
      status: SourceStatus.pending,
      decision: SourceDecision.matchedExisting,
      journalId: 'j1',
      rolledBack: true,
    );
    final recordJson = sourceRecordToJson(record);
    expect(recordJson['amountMinor'], -6325);
    expect(recordJson['raw'], ['01/07/2026', 'WOOLWORTHS', '-63.25', '']);
    expect(
      sourceRecordToJson(sourceRecordFromJson(wire(recordJson), aud)),
      recordJson,
    );
  });

  test('rules and undo records round-trip', () {
    final rule = CategorisationRule(
      id: 'rule1',
      name: 'Supermarkets',
      categoryId: 'groceries',
      priority: 5,
      enabled: false,
      merchant: 'Woolworths',
      descriptionContains: 'eftpos',
      accountIds: {'card', 'bank'},
      minAmount: m('1.00'),
      maxAmount: m('500.00'),
      tags: {'home'},
    );
    final json = categorisationRuleToJson(rule);
    expect(json['minAmountMinor'], 100);
    expect(json['accountIds'], ['bank', 'card']);
    expect(
      categorisationRuleToJson(categorisationRuleFromJson(wire(json), aud)),
      json,
    );

    final undo = RuleUndoRecord(
      id: 'u1',
      appliedAt: DateTime.utc(2026, 7, 10),
      entries: const [
        RuleUndoEntry(
          originalJournalId: 'j1',
          newJournalId: 'j2',
          previousCategoryId: 'uncategorised',
          newCategoryId: 'groceries',
          previousSource: CategorySource.suggestion,
          ruleId: 'rule1',
          inPlace: false,
        ),
      ],
    );
    final undoJson = ruleUndoRecordToJson(undo);
    expect(
      ruleUndoRecordToJson(ruleUndoRecordFromJson(wire(undoJson))),
      undoJson,
    );
  });
}
