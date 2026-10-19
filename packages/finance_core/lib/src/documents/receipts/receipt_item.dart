import 'package:meta/meta.dart';

import '../../money/money.dart';

/// A purchased line the user confirmed on a receipt (P1). Extraction never
/// writes one; it only offers candidates (OCR 03). Item amounts describe
/// the receipt and never post a second expense.
@immutable
class ReceiptItem {
  ReceiptItem({
    required this.id,
    required this.receiptId,
    required this.description,
    required this.lineTotal,
    this.quantityThousandths = 1000,
    this.unit,
    this.unitPrice,
    Money? discount,
    this.gstApplies,
    this.categoryId,
  }) : discount = discount ?? Money.zero(lineTotal.currency);

  final String id;
  final String receiptId;
  final String description;

  /// Quantity in thousandths: 1000 is one.
  final int quantityThousandths;
  final String? unit;
  final Money? unitPrice;

  /// The amount on the line before [discount], in the receipt's currency.
  final Money lineTotal;

  /// A discount on the line, as a positive magnitude.
  final Money discount;

  /// Null when unknown.
  final bool? gstApplies;

  /// An expense category the user chose for the line.
  final String? categoryId;

  Money get netTotal => lineTotal - discount;
}
