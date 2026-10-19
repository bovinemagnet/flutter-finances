import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  OcrResult page(String text) =>
      OcrResult.fromText(text, engine: 'test', engineVersion: '1');

  List<List<int>> pagesOf(ReceiptSeparationProposal proposal) => [
    for (final group in proposal.groups) group.pages,
  ];

  test('two receipts across three pages', () {
    final proposal = proposeReceiptSeparation([
      page('''
COLES SUPERMARKETS
Tax Invoice
Date: 12/03/2026
MILK 2L 3.50
BREAD 4.20
EGGS 6.00'''),
      page('''
BANANAS 2.10
APPLES 5.00
SUBTOTAL 20.80
TOTAL 20.80
EFTPOS 20.80
THANK YOU FOR SHOPPING'''),
      page('''
BUNNINGS WAREHOUSE
Tax Invoice
Date: 14/03/2026
HAMMER 25.00
NAILS 5.00
TOTAL 30.00
VISA 30.00'''),
    ]);

    expect(pagesOf(proposal), [
      [0, 1],
      [2],
    ]);
    final first = proposal.groups[0];
    expect(first.reasons, contains(SeparationReason.documentStart));
    expect(first.reasons, contains(SeparationReason.previousPageWithoutTotal));
    expect(first.confidence, ConfidenceCategory.high);
    expect(first.merchantHint, 'COLES SUPERMARKETS');
    expect(first.dateHint, LocalDate(2026, 3, 12));
    expect(first.needsManualSplit, isFalse);

    final second = proposal.groups[1];
    expect(
      second.reasons,
      containsAll([
        SeparationReason.merchantHeaderAfterTotal,
        SeparationReason.differentMerchant,
        SeparationReason.differentDate,
      ]),
    );
    expect(second.confidence, ConfidenceCategory.high);
    expect(second.merchantHint, 'BUNNINGS WAREHOUSE');

    expect(proposal.boundaries.map((b) => b.startsReceipt), [
      true,
      false,
      true,
    ]);
    expect(proposal.isSingleReceipt, isFalse);
    expect(proposal.pagesNeedingManualSplit, isEmpty);
  });

  group('one receipt over two pages', () {
    test('continues when the first page has no total', () {
      final proposal = proposeReceiptSeparation([
        page('''
OFFICEWORKS
Date: 02/05/2026
PAPER A4 9.00
PENS 4.50'''),
        page('''
STAPLER 12.00
TOTAL 25.50
MASTERCARD 25.50'''),
      ]);
      expect(pagesOf(proposal), [
        [0, 1],
      ]);
      expect(proposal.groups.single.confidence, ConfidenceCategory.high);
      expect(proposal.isSingleReceipt, isTrue);
    });

    test('a repeated letterhead and page marker do not start a receipt', () {
      final proposal = proposeReceiptSeparation([
        page('''
HARVEY NORMAN
Page 1 of 2
Date: 02/05/2026
TELEVISION 1299.00'''),
        page('''
HARVEY NORMAN
Page 2 of 2
Date: 02/05/2026
WALL BRACKET 89.00
TOTAL 1388.00'''),
      ]);
      expect(pagesOf(proposal), [
        [0, 1],
      ]);
      final boundary = proposal.boundaries[1];
      expect(boundary.startsReceipt, isFalse);
      expect(
        boundary.reasons,
        containsAll([
          SeparationReason.continuationMarker,
          SeparationReason.previousPageWithoutTotal,
        ]),
      );
      expect(boundary.confidence, ConfidenceCategory.high);
    });
  });

  test('a page with two short receipts needs a manual split', () {
    final proposal = proposeReceiptSeparation([
      page('''
CAFE BEAN THERE
12/03/2026
FLAT WHITE 4.50
TOTAL 4.50
CARD 4.50
CITY PARKING
12/03/2026
PARKING 2HR 8.00
TOTAL 8.00'''),
    ]);
    expect(pagesOf(proposal), [
      [0],
    ]);
    final group = proposal.groups.single;
    expect(group.needsManualSplit, isTrue);
    expect(group.reasons, contains(SeparationReason.multipleReceiptsOnPage));
    expect(group.confidence, ConfidenceCategory.low);
    expect(proposal.pagesNeedingManualSplit, [0]);
    expect(proposal.isSingleReceipt, isFalse);
  });

  test('a receipt with several total lines is not split', () {
    final proposal = proposeReceiptSeparation([
      page('''
BUNNINGS WAREHOUSE
Date: 02/05/2026
TIMBER 40.00
SUBTOTAL 40.00
TOTAL 40.00
TOTAL PAID 40.00
EFTPOS APPROVED
THANK YOU'''),
    ]);
    expect(proposal.groups.single.needsManualSplit, isFalse);
    expect(proposal.isSingleReceipt, isTrue);
    expect(proposal.groups.single.confidence, ConfidenceCategory.high);
  });

  test('weak evidence is reported with low confidence', () {
    // The second page has its own total but no heading: it may be the end
    // of a cut-off receipt or the tail of the first one.
    final proposal = proposeReceiptSeparation([
      page('''
KMART
Date: 02/05/2026
TOWEL 10.00
TOTAL 10.00'''),
      page('''
CUSHION 15.00
TOTAL 15.00'''),
    ]);
    final boundary = proposal.boundaries[1];
    expect(boundary.startsReceipt, isFalse);
    expect(boundary.confidence, ConfidenceCategory.low);
    expect(
      boundary.reasons,
      containsAll([
        SeparationReason.previousPageTotalled,
        SeparationReason.pageHasOwnTotal,
        SeparationReason.noHeader,
      ]),
    );
    expect(proposal.groups.single.confidence, ConfidenceCategory.low);
  });

  test('a blank page joins the current receipt and is skipped over', () {
    final proposal = proposeReceiptSeparation([
      page('''
ALDI
Date: 02/05/2026
RICE 3.00
TOTAL 3.00'''),
      page(''),
      page('''
JB HI-FI
Date: 03/05/2026
CABLE 19.00
TOTAL 19.00'''),
    ]);
    expect(pagesOf(proposal), [
      [0, 1],
      [2],
    ]);
    expect(proposal.boundaries[1].reasons, {SeparationReason.blankPage});
    expect(
      proposal.groups[1].reasons,
      contains(SeparationReason.merchantHeaderAfterTotal),
    );
  });

  test('a receipt without any total is flagged', () {
    final proposal = proposeReceiptSeparation([
      page('''
CORNER STORE
Date: 02/05/2026
MILK 3.00'''),
    ]);
    final group = proposal.groups.single;
    expect(group.reasons, contains(SeparationReason.noTotalFound));
    expect(group.confidence, ConfidenceCategory.medium);
  });

  test('an empty document has no groups', () {
    expect(proposeReceiptSeparation(const []).groups, isEmpty);
  });

  test('no single receipt in the corpus is reported as several', () {
    final dir = Directory('test/documents/corpus').existsSync()
        ? Directory('test/documents/corpus')
        : Directory('packages/finance_core/test/documents/corpus');
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.txt'),
    );
    expect(files, isNotEmpty);
    for (final file in files) {
      final proposal = proposeReceiptSeparation([
        page(file.readAsStringSync()),
      ]);
      expect(proposal.isSingleReceipt, isTrue, reason: file.path);
    }
  });
}
