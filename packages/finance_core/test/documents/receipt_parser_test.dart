import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

class _FakeProvider implements ExtractionProvider {
  @override
  String get name => 'fake-cloud';

  @override
  String get version => '1';

  @override
  ProviderDataUse get dataUse => const ProviderDataUse(
    requiresConsent: true,
    retention: 'Deleted after processing',
    region: 'Australia',
  );

  @override
  Future<OcrResult> recognise(
    Uint8List bytes,
    DocumentContentType type,
  ) async => OcrResult.fromText(
    'SHOP\nTOTAL 5.00\n',
    engine: name,
    engineVersion: version,
  );
}

Extraction parse(
  String text, {
  ParserSettings settings = const ParserSettings(),
}) => parseReceipt(
  OcrResult.fromText(text, engine: 'test', engineVersion: '1'),
  id: 'x1',
  receiptId: 'r1',
  createdAt: DateTime.utc(2026, 7, 2),
  settings: settings,
);

void main() {
  group('totals (OCR 03, A06)', () {
    test('A06: never takes cash tendered or change as the total', () {
      final e = parse('''
CORNER STORE
12/07/2026
BREAD 4.50
MILK 3.10
TOTAL 63.25
CASH 100.00
CHANGE 36.75
''');
      expect(e.total.first.value, m('63.25'));
      expect(e.total.first.confidence, ConfidenceCategory.high);
      expect(e.cashTendered!.value, m('100.00'));
      expect(e.change!.value, m('36.75'));
      expect(e.total.map((c) => c.value), isNot(contains(m('100.00'))));
      expect(e.total.map((c) => c.value), isNot(contains(m('36.75'))));
    });

    test(
      'A06: infers the total from cash less change when the total line is lost',
      () {
        final e = parse('''
CORNER STORE
BREAD 4.50
CASH TENDERED 100.00
CHANGE DUE 36.75
''');
        expect(e.total.first.value, m('63.25'));
        expect(
          e.total.first.reasons,
          contains(UncertaintyReason.totalInferred),
        );
      },
    );

    test('records provenance: the source line and text', () {
      final e = parse('SHOP\nITEM 5.00\nTOTAL \$5.00\n');
      expect(e.total.first.sourceLines, [2]);
      expect(e.total.first.sourceText, r'TOTAL $5.00');
      expect(e.extractionVersion, receiptParserVersion);
      expect(e.ocr.engine, 'test');
    });

    test('validates subtotal, discount and GST against the total', () {
      final consistent = parse('''
SHOP
SUBTOTAL 50.00
VOUCHER -5.00
TOTAL 45.00
GST INCLUDED 4.09
''');
      expect(consistent.arithmetic, ArithmeticCheck.consistent);
      expect(consistent.total.first.value, m('45.00'));
      expect(consistent.tax.first.value, m('4.09'));

      final exclusive = parse('''
ACME SUPPLIES PTY LTD
Subtotal (ex GST) 100.00
GST 10.00
Total 110.00
''');
      expect(exclusive.arithmetic, ArithmeticCheck.consistent);
      expect(exclusive.total.first.value, m('110.00'));

      final mismatch = parse('SHOP\nSUBTOTAL 50.00\nTOTAL 55.00\n');
      expect(mismatch.arithmetic, ArithmeticCheck.inconsistent);
      expect(
        mismatch.total.first.reasons,
        contains(UncertaintyReason.arithmeticMismatch),
      );
      expect(
        mismatch.reviewReasons,
        contains(UncertaintyReason.arithmeticMismatch),
      );
    });

    test(
      'a GST line mentioning total is tax, a total including GST is total',
      () {
        final e = parse(
          'SHOP\nTOTAL INCLUDES GST \$5.75\nTOTAL (INC GST) \$63.25\n',
        );
        expect(e.total.first.value, m('63.25'));
        expect(e.tax.first.value, m('5.75'));
      },
    );

    test('ignores percentages and informational savings after the total', () {
      final e = parse('''
SUPERMARKET
SUBTOTAL 120.40
TOTAL 120.40
GST 10% 2.15
TOTAL SAVINGS 12.00
EFTPOS 120.40
''');
      expect(e.total.first.value, m('120.40'));
      expect(e.total.first.confidence, ConfidenceCategory.high);
      expect(e.tax.first.value, m('2.15'));
    });

    test('flags several plausible totals with low confidence', () {
      final e = parse('SHOP\nTOTAL 12.00\nTOTAL 21.00\n');
      expect(e.total.map((c) => c.value).toSet(), {m('12.00'), m('21.00')});
      expect(e.total.first.confidence, ConfidenceCategory.low);
      expect(
        e.reviewReasons,
        contains(UncertaintyReason.multiplePlausibleTotals),
      );
    });

    test('prefers the total confirmed by the card payment', () {
      final e = parse('SHOP\nTOTAL 21.00\nTOTAL DUE 12.00\nEFTPOS 21.00\n');
      expect(e.total.first.value, m('21.00'));
      expect(
        e.total.first.reasons,
        isNot(contains(UncertaintyReason.multiplePlausibleTotals)),
      );
    });

    test('merges a label and an amount recognised as separate lines', () {
      final e = parse('SHOP\nTOTAL\n\$42.10\n');
      expect(e.total.first.value, m('42.10'));
      expect(e.total.first.sourceLines, [1, 2]);
    });

    test('reassembles rows from bounding boxes', () {
      final ocr = OcrResult(
        engine: 'test',
        engineVersion: '1',
        lines: const [
          OcrLine('SHOP', box: BoundingBox(10, 10, 100, 20)),
          OcrLine('\$42.10', box: BoundingBox(300, 52, 60, 20)),
          OcrLine('TOTAL', box: BoundingBox(10, 50, 60, 20)),
          OcrLine('CASH', box: BoundingBox(10, 80, 60, 20)),
          OcrLine('\$50.00', box: BoundingBox(300, 81, 60, 20)),
        ],
      );
      final e = parseReceipt(
        ocr,
        id: 'x',
        receiptId: 'r',
        createdAt: DateTime.utc(2026),
      );
      expect(e.total.first.value, m('42.10'));
      expect(e.total.first.sourceLines, [2, 1]);
      expect(e.cashTendered!.value, m('50.00'));
    });

    test('no amount at all means no total and a review flag', () {
      final e = parse('FADED RECEIPT\nTHANK YOU\n');
      expect(e.total, isEmpty);
      expect(e.reviewReasons, contains(UncertaintyReason.missingTotal));
    });
  });

  group('refunds (OCR 04)', () {
    test('detects refund receipts and keeps the total positive', () {
      final e = parse(
        'JB HI-FI\nREFUND\nHEADPHONES -49.00\nTOTAL REFUND -\$49.00\n',
      );
      expect(e.isRefund, isTrue);
      expect(e.total.first.value, m('49.00'));
      expect(e.reviewReasons, contains(UncertaintyReason.refundReceipt));
      expect(e.suggested.isRefund, isTrue);
    });

    test('a CR suffix marks a refund', () {
      final e = parse('STORE\nTOTAL 25.00 CR\n');
      expect(e.isRefund, isTrue);
      expect(e.total.first.value, m('25.00'));
    });
  });

  group('dates (OCR 04)', () {
    test('day-month is the default reading and ambiguity is flagged', () {
      final e = parse('SHOP\n03/07/2026\nTOTAL 1.00\n');
      expect(e.date.first.value, d('2026-07-03'));
      expect(e.date.first.reasons, contains(UncertaintyReason.ambiguousDate));
      expect(e.date.map((c) => c.value), contains(d('2026-03-07')));
      expect(e.reviewReasons, contains(UncertaintyReason.ambiguousDate));
    });

    test('an impossible reading is not ambiguous', () {
      final e = parse('SHOP\n13/07/2026\nTOTAL 1.00\n');
      expect(e.date.single.value, d('2026-07-13'));
      expect(e.date.single.reasons, isEmpty);
      expect(e.date.single.confidence, ConfidenceCategory.high);
    });

    test('month-day can be chosen for the workspace or a merchant', () {
      final workspace = parse(
        'SHOP\n03/07/2026\nTOTAL 1.00\n',
        settings: const ParserSettings(dateConvention: DateConvention.monthDay),
      );
      expect(workspace.date.first.value, d('2026-03-07'));

      final merchant = parse(
        'ACME SOFTWARE INC\nInvoice date 03/07/2026\nTotal USD 10.00\n',
        settings: const ParserSettings(
          merchantDateConventions: {'acme software': DateConvention.monthDay},
        ),
      );
      expect(merchant.date.first.value, d('2026-03-07'));
      expect(
        merchant.date.first.reasons,
        isNot(contains(UncertaintyReason.ambiguousDate)),
      );
    });

    test('reads month names, ISO dates and two-digit years', () {
      expect(parse('SHOP\n19 Oct 2026\n').date.first.value, d('2026-10-19'));
      expect(parse('SHOP\nOct 19, 2026\n').date.first.value, d('2026-10-19'));
      expect(parse('SHOP\n19OCT26 14:02\n').date.first.value, d('2026-10-19'));
      expect(
        parse('SHOP\n2026-10-19T10:00\n').date.first.value,
        d('2026-10-19'),
      );
      expect(parse('SHOP\n19.10.26\n').date.first.value, d('2026-10-19'));
    });

    test('ignores expiry and due dates and prefers labelled dates', () {
      final e = parse('''
TELCO PTY LTD
Due date: 30/07/2026
Invoice date: 14/07/2026
Total 79.00
''');
      expect(e.date.first.value, d('2026-07-14'));
      expect(e.date.map((c) => c.value), isNot(contains(d('2026-07-30'))));
    });

    test('prefers the reading that is not in the future', () {
      final e = parse(
        'SHOP\n09/12/2026\nTOTAL 1.00\n',
        settings: ParserSettings(referenceDate: d('2026-10-01')),
      );
      expect(e.date.first.value, d('2026-09-12'));
    });

    test('flags a future date', () {
      final e = parse(
        'SHOP\n25/12/2026\nTOTAL 1.00\n',
        settings: ParserSettings(referenceDate: d('2026-10-01')),
      );
      expect(e.date.first.reasons, contains(UncertaintyReason.futureDate));
    });
  });

  group('merchant and currency', () {
    test('takes the first meaningful header line and strips decoration', () {
      final e = parse(
        '*** WOOLWORTHS METRO ***\nTown Hall 2000\nABN 88 000 014 675\nTAX INVOICE\nTOTAL 5.00\n',
      );
      expect(e.merchant.first.value, 'WOOLWORTHS METRO');
      expect(
        e.merchant.first.reasons,
        contains(UncertaintyReason.merchantGuessed),
      );
    });

    test('skips generic headings and uses labels when present', () {
      expect(
        parse('TAX INVOICE\nWelcome to Bean There Cafe\n').merchant.first.value,
        'Bean There Cafe',
      );
      final labelled = parse(
        'INVOICE\n123 Fake St\nSold by: Gadget Hub Pty Ltd\n',
      );
      expect(labelled.merchant.first.value, 'Gadget Hub Pty Ltd');
      expect(labelled.merchant.first.confidence, ConfidenceCategory.high);
    });

    test('currency is reported only when explicit', () {
      final implicit = parse('SHOP\nTOTAL \$5.00\n');
      expect(implicit.currency, isEmpty);
      expect(implicit.total.first.value.currency, aud);
      expect(
        implicit.reviewReasons,
        contains(UncertaintyReason.currencyNotExplicit),
      );

      final explicit = parse('SHOP\nTOTAL AUD 5.00\n');
      expect(explicit.currency.single.value, 'AUD');
      expect(
        explicit.reviewReasons,
        isNot(contains(UncertaintyReason.currencyNotExplicit)),
      );

      final foreign = parse('SHOP\nTOTAL US\$5.00\n');
      expect(foreign.currency.single.value, 'USD');
      expect(foreign.total.first.value.currency.code, 'USD');
      expect(
        foreign.reviewReasons,
        contains(UncertaintyReason.foreignCurrency),
      );
    });
  });

  test('A06: a wrong total is corrected at review before anything posts', () {
    // The total row is unreadable and the engine output only shows cash.
    final extraction = parse('CORNER STORE\n11/07/2026\nTOT?L\nCASH 100.00\n');
    var receipt =
        Receipt(
              id: 'r1',
              capturedAt: DateTime.utc(2026, 7, 11),
              source: CaptureSource.camera,
            )
            .withExtractionEvent(ExtractionEvent.queue)
            .withExtractionEvent(ExtractionEvent.start)
            .withExtractionEvent(ExtractionEvent.succeed);
    final review = buildReceiptReview(receipt, extraction);
    expect(review.total.value, isNot(m('100.00')));
    expect(review.total.highlight, isTrue);

    final result = reviewReceipt(
      receipt: receipt,
      confirmed: ReceiptFields(total: m('63.25'), date: review.date.value),
      decision: const CreateExpense(
        accountId: 'cash',
        categoryId: 'groceries',
        paidInCash: true,
        accountConfirmed: true,
      ),
      chart: testChart,
      existingLinks: const [],
      now: DateTime.utc(2026, 7, 11),
    );
    receipt = result.receipt;
    expect(receipt.confirmed.total, m('63.25'));
    expect(result.draft!.amount, m('63.25'));
    expect(result.draft!.status, JournalStatus.posted);
    // Only a draft exists; posting it is a separate confirmed command.
    expect(result.draft, isA<TransactionDraft>());
  });

  group('extraction provider boundary (AUTO 02)', () {
    test(
      'external providers only return recognised text for local parsing',
      () async {
        final provider = _FakeProvider();
        expect(provider.dataUse.requiresConsent, isTrue);
        final ocr = await provider.recognise(
          Uint8List(0),
          DocumentContentType.jpeg,
        );
        final extraction = parse(ocr.text);
        expect(extraction.total.first.value, m('5.00'));
      },
    );
  });

  group('review safety (OCR 03)', () {
    test('rerunning extraction never overwrites a confirmed field', () {
      var receipt = Receipt(
        id: 'r1',
        capturedAt: DateTime.utc(2026),
        source: CaptureSource.camera,
      ).withConfirmedFields(ReceiptFields(total: m('63.25')));
      final rerun = parse('SHOP\n01/07/2026\nTOTAL 100.00\n');
      receipt = receipt.copyWith(latestExtractionId: rerun.id);
      final review = buildReceiptReview(receipt, rerun);
      expect(review.total.value, m('63.25'));
      expect(review.total.origin, FieldOrigin.confirmed);
      expect(review.total.highlight, isFalse);
      expect(review.date.origin, FieldOrigin.extracted);
      expect(review.date.highlight, isTrue);
      expect(receipt.confirmed.total, m('63.25'));
    });

    test('missing fields are highlighted for manual entry', () {
      final receipt = Receipt(
        id: 'r1',
        capturedAt: DateTime.utc(2026),
        source: CaptureSource.camera,
      );
      final review = buildReceiptReview(receipt, null);
      expect(review.total.origin, FieldOrigin.none);
      expect(review.total.highlight, isTrue);
    });

    test('suggested fields come from the leading candidates', () {
      final e = parse('SHOP\n13/07/2026\nTOTAL 9.95\n');
      expect(
        e.suggested,
        ReceiptFields(
          merchant: 'SHOP',
          date: d('2026-07-13'),
          total: m('9.95'),
          isRefund: false,
        ),
      );
      expect(e.text, contains('TOTAL 9.95'));
    });
  });
}
