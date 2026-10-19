import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../planning/rounding.dart';
import '../receipts/receipt_item.dart';
import 'extraction.dart';
import 'ocr_result.dart';
import 'receipt_lines.dart';
import 'receipt_review.dart';

/// Version of the item rules, stored on every item extraction (OCR 03).
const receiptItemParserVersion = 'receipt-items/1';

/// Whether the extracted items add up to the printed subtotal or total.
enum ItemReconciliation { consistent, inconsistent, insufficient }

/// One purchased line read from a receipt (OCR 01, P1). A candidate only:
/// it becomes a [ReceiptItem] when the user confirms it.
@immutable
class ExtractedLineItem {
  ExtractedLineItem({
    required this.description,
    required this.lineTotal,
    required List<int> sourceLines,
    required this.confidence,
    this.quantityThousandths = 1000,
    this.unit,
    this.unitPrice,
    Money? discount,
    this.gstApplies,
    Set<UncertaintyReason> reasons = const {},
  }) : discount = discount ?? Money.zero(lineTotal.currency),
       sourceLines = List.unmodifiable(sourceLines),
       reasons = Set.unmodifiable(reasons);

  final String description;

  /// Quantity in thousandths: 1000 is one, 710 is 0.71 (kg).
  final int quantityThousandths;

  /// `kg`, `g`, `l` or `ea` when printed.
  final String? unit;
  final Money? unitPrice;

  /// The amount printed on the line, before [discount].
  final Money lineTotal;

  /// A discount printed under the line, as a positive magnitude.
  final Money discount;

  /// True or false when the receipt marks GST items; null when it marks
  /// none, so it is unknown.
  final bool? gstApplies;

  /// Indexes into [OcrResult.lines].
  final List<int> sourceLines;
  final ConfidenceCategory confidence;
  final Set<UncertaintyReason> reasons;

  Money get netTotal => lineTotal - discount;

  /// The item as the user confirms it.
  ReceiptItem toReceiptItem({
    required String id,
    required String receiptId,
    String? categoryId,
  }) => ReceiptItem(
    id: id,
    receiptId: receiptId,
    description: description,
    lineTotal: lineTotal,
    quantityThousandths: quantityThousandths,
    unit: unit,
    unitPrice: unitPrice,
    discount: discount,
    gstApplies: gstApplies,
    categoryId: categoryId,
  );
}

/// The items read from one OCR result, with their reconciliation. Like an
/// [Extraction] it is immutable evidence; a rerun creates a new one.
@immutable
class ItemExtraction {
  ItemExtraction({
    required this.id,
    required this.receiptId,
    required this.createdAt,
    required this.extractionVersion,
    required this.currency,
    required List<ExtractedLineItem> items,
    required this.reconciliation,
    required Set<UncertaintyReason> reasons,
    this.extractionId,
    this.subtotal,
    this.total,
    this.difference,
  }) : items = List.unmodifiable(items),
       reasons = Set.unmodifiable(reasons);

  final String id;
  final String receiptId;

  /// The field extraction from the same OCR result, when there is one.
  final String? extractionId;
  final DateTime createdAt;
  final String extractionVersion;
  final Currency currency;
  final List<ExtractedLineItem> items;
  final Money? subtotal;
  final Money? total;
  final ItemReconciliation reconciliation;

  /// What the items would need to add up to, less their net total, for
  /// the check that was made; null when nothing was checked.
  final Money? difference;

  /// Extraction-level reasons such as [UncertaintyReason.itemsDoNotReconcile].
  final Set<UncertaintyReason> reasons;

  /// Sum of every item's net total.
  Money get itemsTotal =>
      items.fold(Money.zero(currency), (sum, i) => sum + i.netTotal);
}

final _qualifier = RegExp(
  r'^(\d+(?:\.\d{1,3})?)\s*(kg|g|l|ea|each)?\s*(?:@|x)\s*'
  r'(?:A\$|\$)?(\d+\.\d{2})\s*(?:/\s*(kg|g|l|ea|each))?\s*(?:ea|each)?'
  r'(?:\s+(?:A\$|\$)?(\d+\.\d{2}))?$',
  caseSensitive: false,
);
final _inlineQualifier = RegExp(
  r'\s(\d+(?:\.\d{1,3})?)\s*(kg|g|l|ea|each)?\s*@\s*(?:A\$|\$)?'
  r'(\d+\.\d{2})\s*(?:/\s*(kg|g|l|ea|each)|ea|each)?\s*$',
  caseSensitive: false,
);
final _multiple = RegExp(r'\s[xX]\s?(\d{1,3})$');
final _marker = RegExp(r'^[*#^]\s*');
final _taxCode = RegExp(r'\s[AGT]$');
final _trailingAmount = RegExp(
  r'\s*(?:A\$|AU\$|\$)?\s?-?\d{1,3}(?:,\d{3})*\.\d{2}(?:\s?CR|-)?\s*$',
  caseSensitive: false,
);
final _letters = RegExp('[A-Za-z]{2}');

int _thousandths(String text) {
  final parts = text.split('.');
  final fraction = parts.length > 1 ? parts[1].padRight(3, '0') : '000';
  return int.parse(parts[0]) * 1000 + int.parse(fraction);
}

String? _unit(String? text) => switch (text?.toLowerCase()) {
  null => null,
  'each' => 'ea',
  final unit => unit,
};

int _minor(String text) => int.parse(text.replaceAll('.', ''));

class _Item {
  _Item(this.description, this.total, this.lines);

  String description;
  final int total;
  final List<int> lines;
  int quantity = 1000;
  String? unit;
  int? unitPrice;
  int discount = 0;
  bool marked = false;
}

/// Reads purchased lines from a receipt (item-level extraction, P1).
///
/// Rows are assembled as for [parseReceipt]. Items are the rows before
/// the first subtotal, total, tax, payment, cash or change row that has
/// an amount; their last amount is the line total. Heuristics, documented
/// for review:
///
/// - A row such as `0.71 kg @ $4.00/kg` or `2 @ 1.50` gives the item above
///   its quantity, unit and unit price; with a trailing amount
///   (`3 @ $1.20  3.60`) it completes a description-only row above it.
///   The same text inside an item row, or a trailing `x2`, is read too
///   (the unit price of `x2` is derived when it divides exactly).
/// - A discount row with a negative amount reduces the item above it;
///   positive "saved" rows are informational and ignored.
/// - A row starting `*`, `#` or `^`, or ending with a tax code `A`, `G` or
///   `T` after the amount, marks GST. When some item is marked, unmarked
///   items have GST false; when none is, GST is unknown (null).
/// - Quantity × unit price, rounded half away from zero, must equal the
///   line total, otherwise [UncertaintyReason.itemArithmeticMismatch].
///
/// Reconciliation is consistent when the items' net total equals the
/// printed subtotal, or the total after the discounts, charges and rounding
/// printed between subtotal and total (with or without the printed tax);
/// inconsistent when a subtotal or total exists and neither holds
/// ([UncertaintyReason.itemsDoNotReconcile]); insufficient without items
/// ([UncertaintyReason.noItemsFound]) or without a subtotal and total
/// ([UncertaintyReason.itemsNotChecked]). Item confidence is high when
/// consistent, medium when insufficient, and low when inconsistent or the
/// line's own arithmetic fails.
ItemExtraction extractReceiptItems(
  OcrResult ocr, {
  required String id,
  required String receiptId,
  required DateTime createdAt,
  String? extractionId,
  Currency currency = Currency.aud,
}) {
  final rows = assembleRows(ocr);
  const endKinds = {
    RowKind.subtotal,
    RowKind.total,
    RowKind.strongTotal,
    RowKind.tax,
    RowKind.payment,
    RowKind.cashTendered,
    RowKind.change,
    RowKind.cashOut,
  };
  final kinds = [for (final r in rows) classifyRow(r)];
  final amounts = [for (final r in rows) amountsIn(r.text)];
  var end = rows.length;
  for (var i = 0; i < rows.length; i++) {
    if (endKinds.contains(kinds[i]) && amounts[i].isNotEmpty) {
      end = i;
      break;
    }
  }

  final items = <_Item>[];
  ReceiptRow? pending;
  for (var i = 0; i < end; i++) {
    final row = rows[i];
    final text = row.text;
    final qualifier = _qualifier.firstMatch(text);
    if (qualifier != null) {
      final quantity = _thousandths(qualifier[1]!);
      final unit = _unit(qualifier[2] ?? qualifier[4]);
      final price = _minor(qualifier[3]!);
      final total = qualifier[5];
      final previous = items.lastOrNull;
      if (total == null && previous != null && previous.unitPrice == null) {
        previous
          ..quantity = quantity
          ..unit = unit
          ..unitPrice = price
          ..lines.addAll(row.lines);
      } else if (total != null) {
        final item =
            _Item(
                pending?.text.replaceFirst(_marker, '').trim() ?? '',
                _minor(total),
                [...?pending?.lines, ...row.lines],
              )
              ..quantity = quantity
              ..unit = unit
              ..unitPrice = price
              ..marked = pending != null && _marker.hasMatch(pending.text);
        items.add(item);
      }
      pending = null;
      continue;
    }
    final found = amounts[i];
    switch (kinds[i]) {
      case RowKind.discount:
        final value = found.lastOrNull;
        if (value != null && value.negative && items.isNotEmpty) {
          items.last
            ..discount += value.minor
            ..lines.addAll(row.lines);
        }
        pending = null;
      case RowKind.item || RowKind.charge:
        if (found.isEmpty) {
          if (_letters.hasMatch(text)) pending = row;
          continue;
        }
        final last = found.last;
        var description = text.replaceFirst(_marker, '');
        final marked =
            description != text || _taxCode.hasMatch(description.trim());
        description = description
            .trim()
            .replaceFirst(_taxCode, '')
            .replaceFirst(_trailingAmount, '')
            .trim();
        final item = _Item(
          description,
          last.negative ? -last.minor : last.minor,
          [...row.lines],
        )..marked = marked;
        final inline = _inlineQualifier.firstMatch(' $description');
        final multiple = _multiple.firstMatch(description);
        if (inline != null) {
          item
            ..quantity = _thousandths(inline[1]!)
            ..unit = _unit(inline[2] ?? inline[4])
            ..unitPrice = _minor(inline[3]!)
            ..description = ' $description'.substring(0, inline.start).trim();
        } else if (multiple != null) {
          final count = int.parse(multiple[1]!);
          item
            ..quantity = count * 1000
            ..description = description.substring(0, multiple.start).trim();
          if (count > 0 && item.total % count == 0) {
            item.unitPrice = item.total ~/ count;
          }
        }
        items.add(item);
        pending = null;
      default:
        pending = null;
    }
  }

  // The printed subtotal and total after the items.
  int? subtotal;
  int? total;
  int? tax;
  var adjustments = 0;
  for (var i = end; i < rows.length; i++) {
    final value = amounts[i].lastOrNull;
    if (value == null) continue;
    final signed = value.negative ? -value.minor : value.minor;
    switch (kinds[i]) {
      case RowKind.subtotal when subtotal == null && total == null:
        subtotal = value.minor;
      case RowKind.tax when tax == null && total == null:
        tax = value.minor;
      case RowKind.discount when total == null && subtotal != null:
        adjustments -= value.minor;
      case RowKind.charge when total == null && subtotal != null:
        adjustments += value.minor;
      case RowKind.rounding when total == null && subtotal != null:
        adjustments += signed;
      case RowKind.total || RowKind.strongTotal
          when total == null && value.minor != 0:
        total = value.minor;
      default:
    }
  }

  final net = items.fold<int>(0, (sum, i) => sum + i.total - i.discount);
  final reasons = <UncertaintyReason>{};
  ItemReconciliation reconciliation;
  int? difference;
  if (items.isEmpty) {
    reconciliation = ItemReconciliation.insufficient;
    reasons.add(UncertaintyReason.noItemsFound);
  } else if (subtotal == null && total == null) {
    reconciliation = ItemReconciliation.insufficient;
    reasons.add(UncertaintyReason.itemsNotChecked);
  } else {
    final viaSubtotal = subtotal != null && net == subtotal;
    final afterAdjustments = net + adjustments;
    final viaTotal =
        total != null &&
        (afterAdjustments == total ||
            (tax != null && afterAdjustments + tax == total));
    if (viaSubtotal || viaTotal) {
      reconciliation = ItemReconciliation.consistent;
      difference = 0;
    } else {
      reconciliation = ItemReconciliation.inconsistent;
      reasons.add(UncertaintyReason.itemsDoNotReconcile);
      difference = subtotal != null
          ? subtotal - net
          : total! - afterAdjustments;
    }
  }

  final anyMarked = items.any((i) => i.marked);
  final base = switch (reconciliation) {
    ItemReconciliation.consistent => ConfidenceCategory.high,
    ItemReconciliation.insufficient => ConfidenceCategory.medium,
    ItemReconciliation.inconsistent => ConfidenceCategory.low,
  };
  Money money(int minor) => Money(minor, currency);
  return ItemExtraction(
    id: id,
    receiptId: receiptId,
    extractionId: extractionId,
    createdAt: createdAt.toUtc(),
    extractionVersion: receiptItemParserVersion,
    currency: currency,
    items: [
      for (final item in items)
        () {
          final price = item.unitPrice;
          final multiplies =
              price == null ||
              scaleHalfUp(price, item.quantity, 1000) == item.total;
          return ExtractedLineItem(
            description: item.description,
            lineTotal: money(item.total),
            sourceLines: item.lines,
            confidence: multiplies ? base : ConfidenceCategory.low,
            quantityThousandths: item.quantity,
            unit: item.unit,
            unitPrice: price == null ? null : money(price),
            discount: money(item.discount),
            gstApplies: anyMarked ? item.marked : null,
            reasons: {
              if (!multiplies) UncertaintyReason.itemArithmeticMismatch,
            },
          );
        }(),
    ],
    reconciliation: reconciliation,
    reasons: reasons,
    subtotal: subtotal == null ? null : money(subtotal),
    total: total == null ? null : money(total),
    difference: difference == null ? null : money(difference),
  );
}

/// Items for the review screen: confirmed items win, extracted ones are
/// offered as suggestions (OCR 03).
@immutable
class ReceiptItemsReview {
  ReceiptItemsReview({
    required this.origin,
    required List<ReceiptItem> items,
    required List<ExtractedLineItem> suggestions,
    required Set<UncertaintyReason> reasons,
    this.reconciliation,
  }) : items = List.unmodifiable(items),
       suggestions = List.unmodifiable(suggestions),
       reasons = Set.unmodifiable(reasons);

  /// [FieldOrigin.confirmed] once the user has confirmed any item.
  final FieldOrigin origin;

  /// The confirmed items, exactly as saved.
  final List<ReceiptItem> items;

  /// The latest extraction's items, never applied without confirmation.
  final List<ExtractedLineItem> suggestions;
  final Set<UncertaintyReason> reasons;
  final ItemReconciliation? reconciliation;
}

/// Combines [confirmed] items with the latest [extraction]. Rerunning
/// extraction only changes the suggestions; it never replaces or edits a
/// confirmed item.
ReceiptItemsReview reviewReceiptItems(
  List<ReceiptItem> confirmed,
  ItemExtraction? extraction,
) => ReceiptItemsReview(
  origin: confirmed.isNotEmpty
      ? FieldOrigin.confirmed
      : extraction != null && extraction.items.isNotEmpty
      ? FieldOrigin.extracted
      : FieldOrigin.none,
  items: confirmed,
  suggestions: extraction?.items ?? const [],
  reasons: extraction?.reasons ?? const {},
  reconciliation: extraction?.reconciliation,
);
