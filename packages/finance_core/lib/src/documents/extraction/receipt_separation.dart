import 'package:meta/meta.dart';

import '../../time/local_date.dart';
import '../text/normalise.dart';
import 'extraction.dart';
import 'ocr_result.dart';
import 'receipt_dates.dart';
import 'receipt_lines.dart';

/// Why a page was proposed to start a receipt, continue one, or why a
/// proposed receipt needs a careful look.
enum SeparationReason {
  /// The first page of the document.
  documentStart('DOCUMENT_START'),

  /// The previous page printed a total and this page opens with a
  /// merchant heading.
  merchantHeaderAfterTotal('MERCHANT_HEADER_AFTER_TOTAL'),

  /// The previous page printed a total, but this page has no heading.
  previousPageTotalled('PREVIOUS_PAGE_TOTALLED'),

  /// This page and the previous one each print their own total.
  pageHasOwnTotal('PAGE_HAS_OWN_TOTAL'),

  /// The heading names a different merchant from the current receipt.
  differentMerchant('DIFFERENT_MERCHANT'),

  /// The page shows a different date from the current receipt.
  differentDate('DIFFERENT_DATE'),

  /// A `Page 1 of n` marker on a later page.
  firstPageMarker('FIRST_PAGE_MARKER'),

  /// The previous page has no total, so the receipt has not ended.
  previousPageWithoutTotal('PREVIOUS_PAGE_WITHOUT_TOTAL'),

  /// The page does not open with a merchant heading.
  noHeader('NO_HEADER'),

  /// A `Page 2 of 3` or `continued` marker.
  continuationMarker('CONTINUATION_MARKER'),

  /// The page has no recognised text; it joins the current receipt.
  blankPage('BLANK_PAGE'),

  /// A total, then a merchant heading, items and another total on one
  /// page: two receipts that need splitting by hand.
  multipleReceiptsOnPage('MULTIPLE_RECEIPTS_ON_PAGE'),

  /// No page of the proposed receipt prints a total.
  noTotalFound('NO_TOTAL_FOUND');

  const SeparationReason(this.code);
  final String code;
}

/// The decision for one page: whether it starts a new receipt.
@immutable
class PageBoundary {
  PageBoundary({
    required this.page,
    required this.startsReceipt,
    required Set<SeparationReason> reasons,
    required this.confidence,
  }) : reasons = Set.unmodifiable(reasons);

  /// Zero-based page index.
  final int page;
  final bool startsReceipt;

  /// The evidence weighed for the decision, for and against.
  final Set<SeparationReason> reasons;
  final ConfidenceCategory confidence;
}

/// Consecutive pages proposed as one receipt.
@immutable
class ReceiptPageGroup {
  ReceiptPageGroup({
    required List<int> pages,
    required Set<SeparationReason> reasons,
    required this.confidence,
    required this.needsManualSplit,
    this.merchantHint,
    this.dateHint,
  }) : pages = List.unmodifiable(pages),
       reasons = Set.unmodifiable(reasons);

  /// Zero-based page indexes, in document order.
  final List<int> pages;

  /// Reasons from every page decision in the group plus group-level
  /// findings ([SeparationReason.noTotalFound],
  /// [SeparationReason.multipleReceiptsOnPage]).
  final Set<SeparationReason> reasons;

  /// The weakest decision in the group, lowered for the findings above.
  final ConfidenceCategory confidence;

  /// A page of the group holds more than one receipt; automatic separation
  /// stops at page level, so the user splits it by hand.
  final bool needsManualSplit;

  /// The first merchant heading in the group, as printed.
  final String? merchantHint;

  /// The first date printed in the group.
  final LocalDate? dateHint;
}

/// A suggested division of a multi-page document into receipts. It is a
/// proposal only: nothing is split, created or changed until the user
/// confirms it.
@immutable
class ReceiptSeparationProposal {
  ReceiptSeparationProposal({
    required List<PageBoundary> boundaries,
    required List<ReceiptPageGroup> groups,
  }) : boundaries = List.unmodifiable(boundaries),
       groups = List.unmodifiable(groups);

  /// One decision per page.
  final List<PageBoundary> boundaries;
  final List<ReceiptPageGroup> groups;

  /// Whether the whole document looks like one receipt.
  bool get isSingleReceipt =>
      groups.length == 1 && !groups.single.needsManualSplit;

  /// Pages that appear to hold more than one receipt.
  List<int> get pagesNeedingManualSplit => [
    for (final b in boundaries)
      if (b.reasons.contains(SeparationReason.multipleReceiptsOnPage)) b.page,
  ];
}

/// Proposes where receipts start in a document with one [OcrResult] per
/// page (REC 05, P1 automatic separation of multi-receipt documents).
///
/// Every page after the first is scored; a score of 2 or more starts a
/// new receipt. Evidence for a new receipt: the previous page printed a
/// total and this page opens with a merchant heading (+3), or printed a
/// total without a heading here (+1); this page and the previous one both
/// print a total (+1); the heading names another merchant (+2); a
/// different date (+1); a `Page 1 of n` marker (+2). Evidence for a
/// continuation: the previous page has no total (−2); no heading (−1); a
/// `Page k of n` (k > 1) or `continued` marker (−3).
///
/// A start scoring 4 or more is high confidence, 3 medium, 2 low. A
/// continuation scoring −2 or less is high, −1 or 0 medium, 1 low. Blank
/// pages join the current receipt with medium confidence and are skipped
/// when looking at the previous page. A group's confidence is its weakest
/// decision, at most medium when no page prints a total and low when a
/// page appears to hold two receipts (a total followed by a merchant
/// heading, items and another total).
///
/// A heading is a row near the top of the page, before any amount, with
/// at least three letters and no amount or date that is not boilerplate
/// such as `Tax invoice`, `ABN` or a page marker. Totals are rows the
/// receipt parser classifies as totals.
ReceiptSeparationProposal proposeReceiptSeparation(
  List<OcrResult> pages, {
  DateConvention dateConvention = DateConvention.dayMonth,
}) {
  final features = [for (final p in pages) _PageFeatures(p, dateConvention)];
  final boundaries = <PageBoundary>[];
  final groups = <List<int>>[];
  String? groupMerchant;
  LocalDate? groupDate;
  _PageFeatures? previous;

  for (var i = 0; i < features.length; i++) {
    final page = features[i];
    final reasons = <SeparationReason>{};
    bool starts;
    ConfidenceCategory confidence;
    if (i == 0) {
      starts = true;
      confidence = ConfidenceCategory.high;
      reasons.add(SeparationReason.documentStart);
    } else if (page.blank) {
      starts = false;
      confidence = ConfidenceCategory.medium;
      reasons.add(SeparationReason.blankPage);
    } else {
      var score = 0;
      void add(SeparationReason reason, int weight) {
        reasons.add(reason);
        score += weight;
      }

      final previousTotalled = previous?.hasTotal ?? false;
      if (previousTotalled) {
        if (page.merchant != null) {
          add(SeparationReason.merchantHeaderAfterTotal, 3);
        } else {
          add(SeparationReason.previousPageTotalled, 1);
        }
        if (page.hasTotal) add(SeparationReason.pageHasOwnTotal, 1);
      } else {
        add(SeparationReason.previousPageWithoutTotal, -2);
      }
      if (page.merchant == null) add(SeparationReason.noHeader, -1);
      if (page.merchant != null &&
          groupMerchant != null &&
          normaliseMerchant(page.merchant!) !=
              normaliseMerchant(groupMerchant)) {
        add(SeparationReason.differentMerchant, 2);
      }
      if (page.date != null && groupDate != null && page.date != groupDate) {
        add(SeparationReason.differentDate, 1);
      }
      switch (page.marker) {
        case _Marker.first:
          add(SeparationReason.firstPageMarker, 2);
        case _Marker.continued:
          add(SeparationReason.continuationMarker, -3);
        case null:
      }
      starts = score >= 2;
      confidence = starts
          ? (score >= 4
                ? ConfidenceCategory.high
                : score == 3
                ? ConfidenceCategory.medium
                : ConfidenceCategory.low)
          : (score <= -2
                ? ConfidenceCategory.high
                : score <= 0
                ? ConfidenceCategory.medium
                : ConfidenceCategory.low);
    }
    if (page.multipleReceipts) {
      reasons.add(SeparationReason.multipleReceiptsOnPage);
    }
    boundaries.add(
      PageBoundary(
        page: i,
        startsReceipt: starts,
        reasons: reasons,
        confidence: confidence,
      ),
    );
    if (starts) {
      groups.add([i]);
      groupMerchant = page.merchant;
      groupDate = page.date;
    } else {
      groups.last.add(i);
      groupMerchant ??= page.merchant;
      groupDate ??= page.date;
    }
    if (!page.blank) previous = page;
  }

  return ReceiptSeparationProposal(
    boundaries: boundaries,
    groups: [
      for (final pageIndexes in groups)
        _group(
          pageIndexes,
          [for (final i in pageIndexes) boundaries[i]],
          [for (final i in pageIndexes) features[i]],
        ),
    ],
  );
}

ReceiptPageGroup _group(
  List<int> pages,
  List<PageBoundary> decisions,
  List<_PageFeatures> features,
) {
  final reasons = {for (final d in decisions) ...d.reasons};
  var confidence = decisions
      .map((d) => d.confidence)
      .reduce((a, b) => a.index >= b.index ? a : b);
  if (!features.any((f) => f.hasTotal)) {
    reasons.add(SeparationReason.noTotalFound);
    if (confidence == ConfidenceCategory.high) {
      confidence = ConfidenceCategory.medium;
    }
  }
  final manual = features.any((f) => f.multipleReceipts);
  if (manual) confidence = ConfidenceCategory.low;
  return ReceiptPageGroup(
    pages: pages,
    reasons: reasons,
    confidence: confidence,
    needsManualSplit: manual,
    merchantHint: features.map((f) => f.merchant).nonNulls.firstOrNull,
    dateHint: features.map((f) => f.date).nonNulls.firstOrNull,
  );
}

enum _Marker { first, continued }

/// How many rows from the top of a page may hold the merchant heading,
/// counting boilerplate rows that are skipped.
const _headingRows = 4;

final _pageMarker = RegExp(
  r'\bpage\s+(\d+)\s*(?:of|/)\s*(\d+)\b',
  caseSensitive: false,
);
final _continued = RegExp(
  r"\b(continued|cont'?d|carried forward|brought forward)\b",
  caseSensitive: false,
);
final _boilerplate = RegExp(
  r'^(tax invoice|invoice|receipt|customer copy|merchant copy|'
  r'cardholder copy|eftpos|thank|thanks|abn|acn|ph\b|phone|tel\b|fax|'
  r'email|www\.|http|order|table|date|time|cashier|operator|served|'
  r'register|store\s*(?:no|#|\d)|trans|docket|copy|duplicate|reprint|page|'
  r'tax\b|gst|total|sub|welcome$|paid|approved|terminal|tid\b|mid\b|'
  r'purchase|signature|please|visit|keep|card|cash|change|balance|'
  r'continued|cont)',
  caseSensitive: false,
);
final _decoration = RegExp(r'^[\s*#=~_|.:\-]+|[\s*#=~_|.:\-]+$');
final _letters = RegExp('[A-Za-z]');
final _leadingNumber = RegExp(r'^\d+[\s,/]');

/// The row as a merchant heading, or null when it does not look like one.
String? _heading(ReceiptRow row, DateConvention convention) {
  final text = row.text.replaceAll(_decoration, '');
  if (_letters.allMatches(text).length < 3) return null;
  if (_leadingNumber.hasMatch(text)) return null;
  if (_boilerplate.hasMatch(text)) return null;
  if (amountsIn(text).isNotEmpty) return null;
  if (datesIn(text, convention).isNotEmpty) return null;
  return text;
}

bool _isTotal(RowKind kind) =>
    kind == RowKind.total || kind == RowKind.strongTotal;

class _PageFeatures {
  _PageFeatures(OcrResult ocr, DateConvention convention) {
    final rows = assembleRows(ocr);
    blank = rows.isEmpty;
    final kinds = [
      for (final row in rows)
        amountsIn(row.text).isEmpty ? null : classifyRow(row),
    ];
    hasTotal = kinds.any((k) => k != null && _isTotal(k));

    for (var i = 0; i < rows.length && i < _headingRows; i++) {
      if (kinds[i] != null) break;
      final heading = _heading(rows[i], convention);
      if (heading != null) {
        merchant = heading;
        break;
      }
    }

    for (final row in rows) {
      final found = datesIn(row.text, convention);
      if (found.isNotEmpty) {
        date = found.first.date;
        break;
      }
    }

    for (final m in _pageMarker.allMatches(ocr.text)) {
      marker = int.parse(m[1]!) == 1 ? _Marker.first : _Marker.continued;
    }
    if (_continued.hasMatch(ocr.text)) marker = _Marker.continued;

    // A total, then a heading, at least one item and another total.
    var stage = 0;
    for (var i = 0; i < rows.length && stage < 4; i++) {
      final kind = kinds[i];
      stage = switch (stage) {
        0 when kind != null && _isTotal(kind) => 1,
        1 when kind == null && _heading(rows[i], convention) != null => 2,
        2 when kind == RowKind.item => 3,
        3 when kind != null && _isTotal(kind) => 4,
        _ => stage,
      };
    }
    multipleReceipts = stage == 4;
  }

  late final bool blank;
  late final bool hasTotal;
  String? merchant;
  LocalDate? date;
  _Marker? marker;
  late final bool multipleReceipts;
}
