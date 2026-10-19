import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

ReceiptSearchEntry entry(
  String id, {
  ReceiptFields confirmed = const ReceiptFields(),
  ReceiptFields suggested = const ReceiptFields(),
  ExtractionState state = ExtractionState.reviewed,
  String? text,
  String? notes,
  Set<String> tags = const {},
  bool linked = false,
  bool image = true,
  DateTime? deletedAt,
}) => ReceiptSearchEntry(
  receipt: Receipt(
    id: id,
    capturedAt: DateTime.utc(2026, 7, 1),
    source: CaptureSource.camera,
    extractionState: state,
    confirmed: confirmed,
    notes: notes,
    tags: tags,
    deletedAt: deletedAt,
  ),
  suggested: suggested,
  extractedText: text,
  assets: [
    if (image)
      DocumentAsset(
        id: '$id-a',
        receiptId: id,
        kind: AssetKind.source,
        contentType: DocumentContentType.jpeg,
        sha256: '00' * 32,
        sizeBytes: 1,
        pageCount: 1,
        createdAt: DateTime.utc(2026, 7, 1),
      ),
  ],
  links: [
    if (linked)
      ReceiptTransactionLink(
        id: '$id-l',
        receiptId: id,
        journalId: 'j',
        allocated: m('1.00'),
        confirmedAt: DateTime.utc(2026, 7, 1),
      ),
  ],
);

List<String> ids(Iterable<ReceiptSearchEntry> entries) =>
    entries.map((e) => e.receipt.id).toList();

void main() {
  final entries = [
    entry(
      'woolies',
      confirmed: ReceiptFields(
        merchant: 'Woolworths Metro',
        date: d('2026-07-03'),
        total: m('63.25'),
      ),
      tags: {'groceries'},
      linked: true,
      text: 'WOOLWORTHS METRO\nMILK 2L 3.10\nTOTAL 63.25',
    ),
    entry(
      'cafe',
      suggested: ReceiptFields(
        merchant: 'Bean There Cafe',
        date: d('2026-07-05'),
        total: m('9.50'),
      ),
      state: ExtractionState.needsReview,
      notes: 'Client meeting',
    ),
    entry('failed', state: ExtractionState.extractionFailed, image: true),
    entry(
      'pending-image',
      confirmed: ReceiptFields(
        merchant: 'Shell',
        date: d('2026-07-01'),
        total: m('80.00'),
      ),
      image: false,
    ),
    entry(
      'deleted',
      confirmed: const ReceiptFields(merchant: 'Woolworths'),
      deletedAt: DateTime.utc(2026, 7, 9),
    ),
  ];

  test(
    'free text matches merchant, notes, tags, amount and extracted text',
    () {
      expect(ids(searchReceipts(entries, const ReceiptQuery(text: 'wool'))), [
        'woolies',
      ]);
      expect(ids(searchReceipts(entries, const ReceiptQuery(text: 'milk'))), [
        'woolies',
      ]);
      expect(ids(searchReceipts(entries, const ReceiptQuery(text: 'client'))), [
        'cafe',
      ]);
      expect(
        ids(searchReceipts(entries, const ReceiptQuery(text: 'groceries'))),
        ['woolies'],
      );
      expect(ids(searchReceipts(entries, const ReceiptQuery(text: '63.25'))), [
        'woolies',
      ]);
      expect(
        ids(searchReceipts(entries, const ReceiptQuery(text: 'bean cafe'))),
        ['cafe'],
      );
    },
  );

  test('merchant, date range and amount filters use confirmed then suggested values', () {
    expect(
      ids(searchReceipts(entries, const ReceiptQuery(merchant: 'Bean There'))),
      ['cafe'],
    );
    expect(
      ids(
        searchReceipts(
          entries,
          ReceiptQuery(from: d('2026-07-02'), to: d('2026-07-31')),
        ),
      ),
      ['cafe', 'woolies'],
    );
    expect(ids(searchReceipts(entries, ReceiptQuery(amount: m('9.50')))), [
      'cafe',
    ]);
    expect(
      ids(
        searchReceipts(
          entries,
          ReceiptQuery(minAmount: m('50.00'), maxAmount: m('70.00')),
        ),
      ),
      ['woolies'],
    );
    expect(
      ids(searchReceipts(entries, const ReceiptQuery(tags: {'groceries'}))),
      ['woolies'],
    );
  });

  test('filters for unmatched, extraction failed and missing image', () {
    expect(
      ids(searchReceipts(entries, const ReceiptQuery(unmatchedOnly: true))),
      ['cafe', 'pending-image', 'failed'],
    );
    expect(
      ids(
        searchReceipts(entries, const ReceiptQuery(extractionFailedOnly: true)),
      ),
      ['failed'],
    );
    expect(
      ids(searchReceipts(entries, const ReceiptQuery(missingImageOnly: true))),
      ['pending-image'],
    );
  });

  test('deleted documents are hidden unless asked for', () {
    expect(
      ids(searchReceipts(entries, const ReceiptQuery())),
      isNot(contains('deleted')),
    );
    expect(
      ids(
        searchReceipts(
          entries,
          const ReceiptQuery(includeDeleted: true, text: 'woolworths'),
        ),
      ),
      containsAll(['woolies', 'deleted']),
    );
  });

  test(
    'an uploaded asset counts as an available image even when not cached',
    () {
      final remote = ReceiptSearchEntry(
        receipt: Receipt(
          id: 'r',
          capturedAt: DateTime.utc(2026, 7, 1),
          source: CaptureSource.camera,
        ),
        assets: [
          DocumentAsset(
            id: 'a',
            receiptId: 'r',
            kind: AssetKind.source,
            contentType: DocumentContentType.png,
            sha256: '00' * 32,
            sizeBytes: 1,
            pageCount: 1,
            createdAt: DateTime.utc(2026, 7, 1),
            presentLocally: false,
            uploadState: UploadState.uploaded,
            cloudCopyConfirmed: true,
          ),
        ],
      );
      expect(remote.hasImage, isTrue);
    },
  );

  test('results are newest first by effective date', () {
    expect(ids(searchReceipts(entries, const ReceiptQuery())), [
      'cafe',
      'woolies',
      'pending-image',
      'failed',
    ]);
  });
}
