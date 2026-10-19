import '../../money/money.dart';
import '../../time/local_date.dart';
import '../extraction/extraction.dart';
import '../extraction/receipt_items.dart';
import 'receipt_item.dart';
import 'warranty.dart';

// JSON formats for receipt items, item extractions and warranties. Money
// is minor units in `...Minor` fields; like receipt fields, items carry
// their currency because a receipt may be in another currency.

UncertaintyReason _reason(String code) =>
    UncertaintyReason.values.firstWhere((r) => r.code == code);

Money? _money(Object? minor, Currency currency) =>
    minor == null ? null : Money(minor as int, currency);

Map<String, Object?> receiptItemToJson(ReceiptItem item) => {
  'id': item.id,
  'receiptId': item.receiptId,
  'description': item.description,
  'quantityThousandths': item.quantityThousandths,
  'unit': item.unit,
  'unitPriceMinor': item.unitPrice?.minor,
  'lineTotalMinor': item.lineTotal.minor,
  'discountMinor': item.discount.minor,
  'currency': item.lineTotal.currency.code,
  'currencyExponent': item.lineTotal.currency.exponent,
  'gstApplies': item.gstApplies,
  'categoryId': item.categoryId,
};

ReceiptItem receiptItemFromJson(Map<String, Object?> json) {
  final currency = Currency(
    json['currency'] as String,
    json['currencyExponent'] as int? ?? 2,
  );
  return ReceiptItem(
    id: json['id'] as String,
    receiptId: json['receiptId'] as String,
    description: json['description'] as String,
    quantityThousandths: json['quantityThousandths'] as int? ?? 1000,
    unit: json['unit'] as String?,
    unitPrice: _money(json['unitPriceMinor'], currency),
    lineTotal: Money(json['lineTotalMinor'] as int, currency),
    discount: _money(json['discountMinor'], currency),
    gstApplies: json['gstApplies'] as bool?,
    categoryId: json['categoryId'] as String?,
  );
}

Map<String, Object?> itemExtractionToJson(ItemExtraction e) => {
  'id': e.id,
  'receiptId': e.receiptId,
  'extractionId': e.extractionId,
  'createdAt': e.createdAt.toUtc().toIso8601String(),
  'extractionVersion': e.extractionVersion,
  'currency': e.currency.code,
  'currencyExponent': e.currency.exponent,
  'items': [
    for (final i in e.items)
      {
        'description': i.description,
        'quantityThousandths': i.quantityThousandths,
        'unit': i.unit,
        'unitPriceMinor': i.unitPrice?.minor,
        'lineTotalMinor': i.lineTotal.minor,
        'discountMinor': i.discount.minor,
        'gstApplies': i.gstApplies,
        'sourceLines': i.sourceLines,
        'confidence': i.confidence.name,
        'reasons': [for (final r in i.reasons) r.code],
      },
  ],
  'subtotalMinor': e.subtotal?.minor,
  'totalMinor': e.total?.minor,
  'differenceMinor': e.difference?.minor,
  'reconciliation': e.reconciliation.name,
  'reasons': [for (final r in e.reasons) r.code],
};

ItemExtraction itemExtractionFromJson(Map<String, Object?> json) {
  final currency = Currency(
    json['currency'] as String,
    json['currencyExponent'] as int? ?? 2,
  );
  Set<UncertaintyReason> reasons(Object? codes) => {
    for (final code in (codes as List? ?? const []).cast<String>())
      _reason(code),
  };
  return ItemExtraction(
    id: json['id'] as String,
    receiptId: json['receiptId'] as String,
    extractionId: json['extractionId'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    extractionVersion: json['extractionVersion'] as String,
    currency: currency,
    items: [
      for (final raw in (json['items'] as List).cast<Map<String, Object?>>())
        ExtractedLineItem(
          description: raw['description'] as String,
          quantityThousandths: raw['quantityThousandths'] as int? ?? 1000,
          unit: raw['unit'] as String?,
          unitPrice: _money(raw['unitPriceMinor'], currency),
          lineTotal: Money(raw['lineTotalMinor'] as int, currency),
          discount: _money(raw['discountMinor'], currency),
          gstApplies: raw['gstApplies'] as bool?,
          sourceLines: (raw['sourceLines'] as List).cast<int>(),
          confidence: ConfidenceCategory.values.byName(
            raw['confidence'] as String,
          ),
          reasons: reasons(raw['reasons']),
        ),
    ],
    subtotal: _money(json['subtotalMinor'], currency),
    total: _money(json['totalMinor'], currency),
    difference: _money(json['differenceMinor'], currency),
    reconciliation: ItemReconciliation.values.byName(
      json['reconciliation'] as String,
    ),
    reasons: reasons(json['reasons']),
  );
}

Map<String, Object?> warrantyToJson(Warranty w) => {
  'id': w.id,
  'receiptId': w.receiptId,
  'itemId': w.itemId,
  'description': w.description,
  'startDate': w.startDate.toString(),
  'months': w.months,
  'days': w.days,
  'reminderLeadDays': w.reminderLeadDays,
  'notes': w.notes,
};

Warranty warrantyFromJson(Map<String, Object?> json) => Warranty(
  id: json['id'] as String,
  receiptId: json['receiptId'] as String,
  itemId: json['itemId'] as String?,
  description: json['description'] as String,
  startDate: LocalDate.parse(json['startDate'] as String),
  months: json['months'] as int? ?? 0,
  days: json['days'] as int? ?? 0,
  reminderLeadDays: (json['reminderLeadDays'] as List? ?? const [30])
      .cast<int>(),
  notes: json['notes'] as String?,
);
