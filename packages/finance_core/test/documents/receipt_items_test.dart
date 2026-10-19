import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

OcrResult corpus(String name) {
  var dir = Directory.current;
  while (!Directory('${dir.path}/test/documents/corpus').existsSync()) {
    dir = dir.parent;
  }
  return OcrResult.fromText(
    File('${dir.path}/test/documents/corpus/$name').readAsStringSync(),
    engine: 'test',
    engineVersion: '1',
  );
}

ItemExtraction items(OcrResult ocr) => extractReceiptItems(
  ocr,
  id: 'ie1',
  receiptId: 'r1',
  extractionId: 'e1',
  createdAt: DateTime.utc(2026, 10, 19),
);

void main() {
  group('item extraction', () {
    test('reads items, weights and GST marks that add up to the subtotal', () {
      final result = items(corpus('supermarket-woolworths.txt'));
      expect(
        [for (final i in result.items) i.description],
        [
          'BANANAS CAVENDISH',
          'MILK FULL CREAM 2L',
          'BREAD WHOLEMEAL 700G',
          'EGGS FREE RANGE 12PK',
          'CHEESE TASTY 500G',
        ],
      );
      final bananas = result.items.first;
      expect(bananas.quantityThousandths, 710);
      expect(bananas.unit, 'kg');
      expect(bananas.unitPrice, m('4.00'));
      expect(bananas.lineTotal, m('2.84'));
      expect(bananas.sourceLines, [5, 6]);
      expect(
        [for (final i in result.items) i.gstApplies],
        [false, false, true, false, false],
      );
      expect(result.itemsTotal, m('25.34'));
      expect(result.subtotal, m('25.34'));
      expect(result.reconciliation, ItemReconciliation.consistent);
      expect(result.difference, m('0.00'));
      expect(result.reasons, isEmpty);
      expect(
        result.items.map((i) => i.confidence),
        everyElement(ConfidenceCategory.high),
      );
    });

    test('attaches an item discount and ignores informational savings', () {
      final costco = items(corpus('long-costco.txt'));
      final tabs = costco.items.firstWhere(
        (i) => i.description.contains('DISHWASHER TABS'),
      );
      expect(tabs.lineTotal, m('29.99'));
      expect(tabs.discount, m('6.00'));
      expect(tabs.netTotal, m('23.99'));
      expect(tabs.gstApplies, isTrue);
      expect(costco.items, hasLength(7));
      expect(costco.reconciliation, ItemReconciliation.consistent);

      final coles = items(corpus('supermarket-coles-savings.txt'));
      expect(coles.items, hasLength(5));
      expect(coles.items[1].discount, m('0.00'));
      expect(coles.items.map((i) => i.gstApplies), everyElement(isNull));
      expect(coles.reconciliation, ItemReconciliation.consistent);
    });

    test('reads printed multiples', () {
      final result = items(corpus('long-bunnings-multiple-totals.txt'));
      final tape = result.items.firstWhere(
        (i) => i.description.startsWith('MASKING TAPE'),
      );
      expect(tape.description, 'MASKING TAPE 48MM');
      expect(tape.quantityThousandths, 2000);
      expect(tape.unitPrice, m('5.98'));
      expect(result.items, hasLength(9));
      expect(result.reconciliation, ItemReconciliation.consistent);
    });

    test('a quantity line can carry the total for the item above', () {
      final result = items(
        OcrResult.fromText(
          'CORNER STORE\nAPPLES PINK LADY\n 3 @ \$1.20   3.60\n'
          'MILK 2L   3.10\nTOTAL   6.70\n',
          engine: 't',
          engineVersion: '1',
        ),
      );
      final apples = result.items.first;
      expect(apples.description, 'APPLES PINK LADY');
      expect(apples.quantityThousandths, 3000);
      expect(apples.unitPrice, m('1.20'));
      expect(apples.lineTotal, m('3.60'));
      expect(result.subtotal, isNull);
      expect(result.total, m('6.70'));
      expect(result.reconciliation, ItemReconciliation.consistent);
    });

    test('flags items that do not reconcile or do not multiply out', () {
      final result = items(
        OcrResult.fromText(
          'SHOP\nWIDGET 2 @ 1.50   3.50\nGADGET   4.00\n'
          'SUBTOTAL   9.00\nTOTAL   9.00\n',
          engine: 't',
          engineVersion: '1',
        ),
      );
      expect(result.items.first.reasons, {
        UncertaintyReason.itemArithmeticMismatch,
      });
      expect(result.items.first.confidence, ConfidenceCategory.low);
      expect(result.reconciliation, ItemReconciliation.inconsistent);
      expect(result.difference, m('1.50'));
      expect(result.reasons, {UncertaintyReason.itemsDoNotReconcile});

      final none = items(
        OcrResult.fromText('TOTAL 5.00', engine: 't', engineVersion: '1'),
      );
      expect(none.items, isEmpty);
      expect(none.reconciliation, ItemReconciliation.insufficient);
      expect(none.reasons, {UncertaintyReason.noItemsFound});

      final unchecked = items(
        OcrResult.fromText('SHOP\nTEA 4.00', engine: 't', engineVersion: '1'),
      );
      expect(unchecked.reconciliation, ItemReconciliation.insufficient);
      expect(unchecked.reasons, {UncertaintyReason.itemsNotChecked});
      expect(unchecked.items.single.confidence, ConfidenceCategory.medium);
    });

    test('runs over the whole corpus without failing', () {
      final names = [
        for (final file in Directory('test/documents/corpus').listSync())
          if (file.path.endsWith('.txt')) file.uri.pathSegments.last,
      ];
      final outcomes = {
        for (final name in names) name: items(corpus(name)).reconciliation,
      };
      printOnFailure('$outcomes');
      expect(outcomes.length, greaterThanOrEqualTo(30));
      expect(
        outcomes.values.where((o) => o == ItemReconciliation.consistent),
        hasLength(greaterThanOrEqualTo(10)),
      );
    });

    test('round-trips through JSON', () {
      final result = items(corpus('supermarket-woolworths.txt'));
      final back = itemExtractionFromJson(itemExtractionToJson(result));
      expect(back.id, 'ie1');
      expect(back.extractionId, 'e1');
      expect(back.items.first.quantityThousandths, 710);
      expect(back.items.first.unitPrice, m('4.00'));
      expect(back.items[2].gstApplies, isTrue);
      expect(back.reconciliation, ItemReconciliation.consistent);
      expect(back.itemsTotal, m('25.34'));
    });
  });

  group('confirmed items', () {
    final extraction = items(corpus('supermarket-woolworths.txt'));

    test('extracted items are suggestions until confirmed', () {
      final review = reviewReceiptItems(const [], extraction);
      expect(review.origin, FieldOrigin.extracted);
      expect(review.items, isEmpty);
      expect(review.suggestions, hasLength(5));
    });

    test('a rerun never replaces confirmed items', () {
      final confirmed = [
        extraction.items.first.toReceiptItem(
          id: 'i1',
          receiptId: 'r1',
          categoryId: 'groceries',
        ),
      ];
      final rerun = items(corpus('supermarket-woolworths.txt'));
      final review = reviewReceiptItems(confirmed, rerun);
      expect(review.origin, FieldOrigin.confirmed);
      expect(review.items.single.id, 'i1');
      expect(review.items.single.categoryId, 'groceries');
      expect(review.suggestions, hasLength(5));

      final json = receiptItemToJson(confirmed.single);
      expect(json['lineTotalMinor'], 284);
      expect(json['quantityThousandths'], 710);
      final back = receiptItemFromJson(json);
      expect(back.description, 'BANANAS CAVENDISH');
      expect(back.unitPrice, m('4.00'));
      expect(back.categoryId, 'groceries');
    });

    test('nothing extracted and nothing confirmed', () {
      final review = reviewReceiptItems(const [], null);
      expect(review.origin, FieldOrigin.none);
      expect(review.suggestions, isEmpty);
    });
  });

  group('warranties', () {
    final warranty = Warranty(
      id: 'w1',
      receiptId: 'r1',
      itemId: 'i1',
      description: 'Dishwasher',
      startDate: d('2026-10-19'),
      months: 24,
      reminderLeadDays: const [30, 7],
    );

    test('cover ends the day before the period is complete', () {
      expect(warranty.expiresOn, d('2028-10-18'));
      expect(warranty.isActiveOn(d('2028-10-18')), isTrue);
      expect(warranty.isActiveOn(d('2028-10-19')), isFalse);
      final days = Warranty(
        id: 'w2',
        receiptId: 'r1',
        description: 'Kettle',
        startDate: d('2026-01-31'),
        months: 1,
        days: 10,
      );
      expect(days.expiresOn, d('2026-03-09'));
    });

    test('plans reminders before expiry with hidden details', () {
      final reminders = warrantyReminders(
        warranty,
        preference: const ReminderPreference(
          minuteOfDay: 23 * 60,
          quietStartMinute: 22 * 60,
          quietEndMinute: 7 * 60,
        ),
      );
      expect(
        [for (final r in reminders) r.remindOn],
        [d('2028-09-19'), d('2028-10-12')],
      );
      // 23:00 is inside overnight quiet hours, so it moves to 07:00 the
      // next morning, as schedule reminders do.
      expect(reminders.first.minuteOfDay, 7 * 60);
      expect(reminders.first.scheduleId, 'w1');
      expect(reminders.first.originalDate, d('2028-10-18'));
      expect(reminders.first.text, 'A warranty ends on 2028-10-18');
      final detailed = warrantyReminders(
        warranty,
        preference: const ReminderPreference(showDetails: true),
        today: d('2028-10-01'),
      );
      expect(
        detailed.single.text,
        'Warranty for Dishwasher ends on 2028-10-18',
      );
      expect(
        warrantyReminders(
          warranty,
          preference: const ReminderPreference(enabled: false),
        ),
        isEmpty,
      );
    });

    test('round-trips through JSON', () {
      final json = warrantyToJson(warranty);
      expect(json, {
        'id': 'w1',
        'receiptId': 'r1',
        'itemId': 'i1',
        'description': 'Dishwasher',
        'startDate': '2026-10-19',
        'months': 24,
        'days': 0,
        'reminderLeadDays': [30, 7],
        'notes': null,
      });
      final back = warrantyFromJson(json);
      expect(back.expiresOn, warranty.expiresOn);
      expect(back.reminderLeadDays, [30, 7]);
    });
  });
}
