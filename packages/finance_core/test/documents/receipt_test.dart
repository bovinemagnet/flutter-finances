import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

Receipt newReceipt({String id = 'r1'}) => Receipt(
  id: id,
  capturedAt: DateTime.utc(2026, 7, 1, 1),
  source: CaptureSource.camera,
);

DocumentAsset asset({
  String id = 'a1',
  String receiptId = 'r1',
  AssetKind kind = AssetKind.source,
  UploadState upload = UploadState.uploadQueued,
  bool present = true,
  bool cloud = false,
}) => DocumentAsset(
  id: id,
  receiptId: receiptId,
  kind: kind,
  contentType: DocumentContentType.jpeg,
  sha256: 'ab' * 32,
  sizeBytes: 1000,
  pageCount: 1,
  presentLocally: present,
  uploadState: upload,
  cloudCopyConfirmed: cloud,
  createdAt: DateTime.utc(2026, 7, 1, 1),
);

void main() {
  group('extraction state machine (REC 04)', () {
    test('follows the happy path to review', () {
      var receipt = newReceipt();
      expect(receipt.extractionState, ExtractionState.captured);
      for (final event in [
        ExtractionEvent.queue,
        ExtractionEvent.start,
        ExtractionEvent.succeed,
        ExtractionEvent.review,
      ]) {
        receipt = receipt.withExtractionEvent(event);
      }
      expect(receipt.extractionState, ExtractionState.reviewed);
    });

    test('failure keeps the receipt and allows retry or manual entry', () {
      final failed = newReceipt()
          .withExtractionEvent(ExtractionEvent.queue)
          .withExtractionEvent(ExtractionEvent.start)
          .withExtractionEvent(ExtractionEvent.fail);
      expect(failed.extractionState, ExtractionState.extractionFailed);
      expect(
        failed.withExtractionEvent(ExtractionEvent.retry).extractionState,
        ExtractionState.extractionQueued,
      );
      expect(
        failed.withExtractionEvent(ExtractionEvent.review).extractionState,
        ExtractionState.reviewed,
      );
    });

    test('a receipt can be reviewed manually without any extraction', () {
      expect(
        newReceipt()
            .withExtractionEvent(ExtractionEvent.review)
            .extractionState,
        ExtractionState.reviewed,
      );
    });

    test('illegal transitions throw', () {
      expect(
        () => newReceipt().withExtractionEvent(ExtractionEvent.succeed),
        throwsA(isA<IllegalTransitionException>()),
      );
      expect(
        () =>
            nextExtractionState(ExtractionState.reviewed, ExtractionEvent.fail),
        throwsA(isA<IllegalTransitionException>()),
      );
      expect(
        () => nextExtractionState(
          ExtractionState.extracting,
          ExtractionEvent.review,
        ),
        throwsA(isA<IllegalTransitionException>()),
      );
    });

    test('extraction can be rerun after review', () {
      expect(
        nextExtractionState(ExtractionState.reviewed, ExtractionEvent.rerun),
        ExtractionState.extractionQueued,
      );
    });
  });

  group('upload state machine (REC 04, SYNC 05)', () {
    test('queued, uploading, uploaded with retry after failure', () {
      var a = asset();
      a = a.withUploadEvent(UploadEvent.start);
      expect(a.uploadState, UploadState.uploading);
      a = a.withUploadEvent(UploadEvent.fail);
      expect(a.uploadState, UploadState.uploadFailed);
      a = a
          .withUploadEvent(UploadEvent.retry)
          .withUploadEvent(UploadEvent.start);
      a = a.withUploadEvent(UploadEvent.complete);
      expect(a.uploadState, UploadState.uploaded);
    });

    test('local-only assets are queued when sync is enabled', () {
      expect(
        nextUploadState(UploadState.localOnly, UploadEvent.queue),
        UploadState.uploadQueued,
      );
    });

    test('illegal upload transitions throw', () {
      expect(
        () => asset().withUploadEvent(UploadEvent.complete),
        throwsA(isA<IllegalTransitionException>()),
      );
      expect(
        () => nextUploadState(UploadState.uploaded, UploadEvent.start),
        throwsA(isA<IllegalTransitionException>()),
      );
    });

    test(
      'the two machines are independent: review while upload is pending',
      () {
        final receipt = newReceipt().withExtractionEvent(
          ExtractionEvent.review,
        );
        final pending = asset(upload: UploadState.uploading);
        expect(receipt.extractionState, ExtractionState.reviewed);
        expect(aggregateUploadState([pending]), UploadState.uploading);
      },
    );

    test('aggregate upload state reports the most urgent asset state', () {
      expect(
        aggregateUploadState([
          asset(upload: UploadState.uploaded),
          asset(id: 'a2', upload: UploadState.uploadFailed),
        ]),
        UploadState.uploadFailed,
      );
      expect(
        aggregateUploadState([asset(upload: UploadState.uploaded)]),
        UploadState.uploaded,
      );
      expect(aggregateUploadState([]), isNull);
    });

    test('the cloud copy can only be confirmed once uploaded', () {
      expect(() => asset().withCloudCopyConfirmed(), throwsStateError);
      final uploaded = asset(upload: UploadState.uploaded)
          .withCloudCopyConfirmed();
      expect(uploaded.cloudCopyConfirmed, isTrue);
    });
  });

  group('cache eviction (REC 08)', () {
    test(
      'only uploaded originals with a confirmed cloud copy are evictable',
      () {
        expect(evictionStatus(asset()), EvictionStatus.notUploaded);
        expect(
          evictionStatus(asset(upload: UploadState.uploaded)),
          EvictionStatus.cloudCopyUnconfirmed,
        );
        expect(
          evictionStatus(asset(upload: UploadState.uploaded, cloud: true)),
          EvictionStatus.evictable,
        );
        expect(
          evictionStatus(
            asset(upload: UploadState.uploaded, cloud: true, present: false),
          ),
          EvictionStatus.notPresent,
        );
      },
    );

    test('unsynced originals are never evicted', () {
      for (final state in [
        UploadState.localOnly,
        UploadState.uploadQueued,
        UploadState.uploading,
        UploadState.uploadFailed,
      ]) {
        expect(() => asset(upload: state).evicted(), throwsStateError);
      }
      final evicted = asset(
        upload: UploadState.uploaded,
        cloud: true,
      ).evicted();
      expect(evicted.presentLocally, isFalse);
    });
  });

  group('links (REC 07, A07)', () {
    final journal = expense('j1', '63.25', '2026-07-01', payee: 'Grocer');

    test('A07: attaching a receipt creates a link and changes no balance', () {
      final before = LedgerProjection(testChart, [journal]);
      final result = reviewReceipt(
        receipt: newReceipt(),
        confirmed: ReceiptFields(
          merchant: 'Grocer',
          date: d('2026-07-01'),
          total: m('63.25'),
        ),
        decision: AttachToTransaction(journal),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(result.draft, isNull);
      expect(result.link!.journalId, 'j1');
      expect(result.link!.allocated, m('63.25'));
      expect(result.receipt.extractionState, ExtractionState.reviewed);
      expect(result.receipt.outcome, ReviewOutcome.attachedToTransaction);
      final after = LedgerProjection(testChart, [journal]);
      expect(after.displayBalance('bank'), before.displayBalance('bank'));
      expect(
        after.expenses(d('2026-07-01'), d('2026-07-31')),
        before.expenses(d('2026-07-01'), d('2026-07-31')),
      );
    });

    test('allocations cannot exceed the transaction or the receipt total', () {
      final existing = [
        ReceiptTransactionLink(
          id: 'l1',
          receiptId: 'r0',
          journalId: 'j1',
          allocated: m('60.00'),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      ];
      expect(
        validateLink(
          receiptId: 'r1',
          journal: journal,
          allocated: m('5.00'),
          receiptTotal: m('5.00'),
          existing: existing,
        ),
        [LinkError.exceedsTransactionAmount],
      );
      expect(
        validateLink(
          receiptId: 'r1',
          journal: journal,
          allocated: m('3.25'),
          receiptTotal: m('3.00'),
          existing: existing,
        ),
        [LinkError.exceedsReceiptTotal],
      );
      expect(
        validateLink(
          receiptId: 'r0',
          journal: journal,
          allocated: m('1.00'),
          existing: existing,
        ),
        [LinkError.duplicateLink],
      );
      expect(
        validateLink(
          receiptId: 'r1',
          journal: journal,
          allocated: m('0.00'),
          existing: const [],
        ),
        [LinkError.nonPositiveAllocation],
      );
      expect(LinkError.exceedsReceiptTotal.code, 'EXCEEDS_RECEIPT_TOTAL');
    });

    test('one receipt can cover several transactions and vice versa', () {
      final second = expense('j2', '20.00', '2026-07-01');
      final links = <ReceiptTransactionLink>[];
      links.add(
        confirmLink(
          id: 'l1',
          receiptId: 'r1',
          journal: journal,
          allocated: m('63.25'),
          receiptTotal: m('83.25'),
          existing: links,
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      );
      links.add(
        confirmLink(
          id: 'l2',
          receiptId: 'r1',
          journal: second,
          allocated: m('20.00'),
          receiptTotal: m('83.25'),
          existing: links,
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      );
      links.add(
        confirmLink(
          id: 'l3',
          receiptId: 'r2',
          journal: second,
          allocated: m('0.01'),
          existing: links.sublist(0, 1),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      );
      expect(linkedAmountForReceipt('r1', links), m('83.25'));
      expect(linkedAmountForJournal('j2', links.sublist(0, 2)), m('20.00'));
      expect(
        () => confirmLink(
          id: 'l4',
          receiptId: 'r3',
          journal: second,
          allocated: m('20.00'),
          existing: links,
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
        throwsA(isA<LinkException>()),
      );
    });

    test('attaching requires an explicit allocation when amounts differ', () {
      expect(
        () => reviewReceipt(
          receipt: newReceipt(),
          confirmed: ReceiptFields(total: m('80.00')),
          decision: AttachToTransaction(journal),
          chart: testChart,
          existingLinks: const [],
          now: DateTime.utc(2026, 7, 2),
        ),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.allocationRequired,
          ),
        ),
      );
      final partial = reviewReceipt(
        receipt: newReceipt(),
        confirmed: ReceiptFields(total: m('80.00')),
        decision: AttachToTransaction(journal, allocated: m('63.25')),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(partial.link!.allocated, m('63.25'));
    });

    test('removing a link keeps the receipt and its document', () {
      final links = [
        ReceiptTransactionLink(
          id: 'l1',
          receiptId: 'r1',
          journalId: 'j1',
          allocated: m('63.25'),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      ];
      expect(unlink(links, 'l1'), isEmpty);
      expect(() => unlink(links, 'missing'), throwsArgumentError);
    });

    test('links follow a journal through a correction', () {
      final links = [
        ReceiptTransactionLink(
          id: 'l1',
          receiptId: 'r1',
          journalId: 'j1',
          allocated: m('63.25'),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      ];
      final replacement = expense(
        'j1b',
        '63.25',
        '2026-07-01',
        category: 'dining',
      );
      final correction = correctJournal(journal, replacement);
      final moved = relinkAfterCorrection(links, correction);
      expect(moved.single.journalId, 'j1b');
      expect(moved.single.id, 'l1');
      final voided = relinkAfterCorrection(
        links,
        correctJournal(journal, null),
      );
      expect(voided, isEmpty);
    });
  });

  group('review outcomes (REC 06)', () {
    test('create expense produces a draft and a link but never a journal', () {
      final result = reviewReceipt(
        receipt: newReceipt(),
        confirmed: ReceiptFields(
          merchant: 'Grocer',
          date: d('2026-07-01'),
          total: m('63.25'),
        ),
        decision: const CreateExpense(
          accountId: 'card',
          categoryId: 'groceries',
        ),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      final draft = result.draft!;
      expect(draft.type, TransactionType.expense);
      expect(draft.accountId, 'card');
      expect(draft.amount, m('63.25'));
      expect(draft.payee, 'Grocer');
      expect(draft.splits.single.categoryId, 'groceries');
      expect(draft.id, isNotNull);
      expect(result.link!.journalId, draft.id);
      expect(result.receipt.outcome, ReviewOutcome.expenseCreated);
      // The draft builds into a balanced journal when the user posts it.
      final journal = JournalFactory(testChart).build(draft);
      expect(validatePostings(journal.postings), isEmpty);
    });

    test('a refund receipt produces a refund draft', () {
      final result = reviewReceipt(
        receipt: newReceipt(),
        confirmed: ReceiptFields(
          date: d('2026-07-01'),
          total: m('10.00'),
          isRefund: true,
        ),
        decision: const CreateExpense(
          accountId: 'card',
          categoryId: 'groceries',
        ),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(result.draft!.type, TransactionType.refund);
    });

    test('cash purchases need an explicitly confirmed cash account', () {
      ReviewResult review(CreateExpense decision) => reviewReceipt(
        receipt: newReceipt(),
        confirmed: ReceiptFields(date: d('2026-07-01'), total: m('12.00')),
        decision: decision,
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(
        () => review(
          const CreateExpense(accountId: 'cash', categoryId: 'dining'),
        ),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.cashAccountUnconfirmed,
          ),
        ),
      );
      expect(
        () => review(
          const CreateExpense(
            accountId: 'card',
            categoryId: 'dining',
            paidInCash: true,
            accountConfirmed: true,
          ),
        ),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.cashAccountRequired,
          ),
        ),
      );
      final ok = review(
        const CreateExpense(
          accountId: 'cash',
          categoryId: 'dining',
          paidInCash: true,
          accountConfirmed: true,
        ),
      );
      expect(ok.draft!.accountId, 'cash');
    });

    test('create expense needs a total and date in the workspace currency', () {
      ReviewResult review(ReceiptFields fields) => reviewReceipt(
        receipt: newReceipt(),
        confirmed: fields,
        decision: const CreateExpense(
          accountId: 'card',
          categoryId: 'groceries',
        ),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(
        () => review(ReceiptFields(date: d('2026-07-01'))),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.missingTotal,
          ),
        ),
      );
      expect(
        () => review(ReceiptFields(total: m('1.00'))),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.missingDate,
          ),
        ),
      );
      expect(
        () => review(
          ReceiptFields(
            date: d('2026-07-01'),
            total: Money(100, const Currency('USD', 2)),
          ),
        ),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.currencyMismatch,
          ),
        ),
      );
      expect(
        () => reviewReceipt(
          receipt: newReceipt(),
          confirmed: ReceiptFields(date: d('2026-07-01'), total: m('1.00')),
          decision: const CreateExpense(
            accountId: 'card',
            categoryId: 'salary',
          ),
          chart: testChart,
          existingLinks: const [],
          now: DateTime.utc(2026, 7, 2),
        ),
        throwsA(
          isA<ReviewException>().having(
            (e) => e.code,
            'code',
            ReviewErrorCode.invalidDraft,
          ),
        ),
      );
    });

    test('keep document only records the review and nothing financial', () {
      final result = reviewReceipt(
        receipt: newReceipt(),
        confirmed: const ReceiptFields(merchant: 'Warranty card'),
        decision: const KeepDocumentOnly(),
        chart: testChart,
        existingLinks: const [],
        now: DateTime.utc(2026, 7, 2),
      );
      expect(result.draft, isNull);
      expect(result.link, isNull);
      expect(result.receipt.outcome, ReviewOutcome.documentOnly);
      expect(result.receipt.confirmed.merchant, 'Warranty card');
    });

    test('confirmed fields merge: later confirmations keep earlier ones', () {
      final receipt = newReceipt().withConfirmedFields(
        ReceiptFields(total: m('5.00')),
      );
      final merged = receipt.withConfirmedFields(
        const ReceiptFields(merchant: 'Cafe'),
      );
      expect(merged.confirmed.total, m('5.00'));
      expect(merged.confirmed.merchant, 'Cafe');
    });
  });

  group('document deletion (REC 08)', () {
    test('deleting a document keeps the transaction and removes links', () {
      final pages = [
        const ReceiptPage(
          id: 'p1',
          receiptId: 'r1',
          pageNumber: 1,
          sourceAssetId: 'a1',
          derivativeAssetId: 'a2',
        ),
      ];
      final assets = [
        asset(),
        asset(id: 'a2', kind: AssetKind.readableDerivative),
      ];
      final links = [
        ReceiptTransactionLink(
          id: 'l1',
          receiptId: 'r1',
          journalId: 'j1',
          allocated: m('1.00'),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      ];
      final plan = planDocumentDeletion(
        receipt: newReceipt(),
        pages: pages,
        assets: assets,
        links: links,
        now: DateTime.utc(2026, 7, 3),
      );
      expect(plan.receipt.deletedAt, DateTime.utc(2026, 7, 3));
      expect(plan.assetIds, {'a1', 'a2'});
      expect(plan.pageIds, {'p1'});
      expect(plan.linkIds, {'l1'});
      expect(plan.journalIdsKept, {'j1'});
    });
  });
}
