import '../../money/money.dart';
import 'ocr_result.dart';

/// Internal building blocks of the receipt parser: row assembly, amount
/// recognition and line classification.

/// A visual row of the receipt, possibly made of several OCR lines.
class ReceiptRow {
  ReceiptRow(this.lines, this.text) : lower = text.toLowerCase();

  /// Indexes into the OCR result, in reading order.
  final List<int> lines;
  final String text;
  final String lower;
}

/// One amount printed on a row, in minor units with exponent 2.
class PrintedAmount {
  PrintedAmount(this.minor, {required this.negative});

  /// The magnitude.
  final int minor;

  /// Printed with a minus sign, a trailing `-` or `CR`.
  final bool negative;
}

/// Kinds of rows, decided by keywords (see [classifyRow]).
enum RowKind {
  item,
  subtotal,
  tax,
  discount,
  charge,
  rounding,
  total,
  strongTotal,
  payment,
  cashTendered,
  change,
  cashOut,
}

final _amount = RegExp(
  r'(?<![\d.,])(-)?(?:A\$|AU\$|NZ\$|US\$|S\$|\$|€|£)?\s?(-)?'
  r'(\d{1,3}(?:,\d{3})+|\d+)[.,](\d{2})'
  r'(?!\d|[.,]\d|\s?%|\s?(?:l|kg|g|ml|lt|ltr|c/l)\b)'
  r'(\s?CR\b|-)?',
  caseSensitive: false,
);

/// Amounts on a row, left to right. Only values with exactly two decimal
/// places count; percentages, quantities with units, and dates do not.
List<PrintedAmount> amountsIn(String text) => [
  for (final match in _amount.allMatches(text))
    PrintedAmount(
      int.parse(match[3]!.replaceAll(',', '')) * 100 + int.parse(match[4]!),
      negative: match[1] != null || match[2] != null || match[5] != null,
    ),
];

final _amountOnly = RegExp(
  r'^\W*(?:aud|usd|nzd)?\s*(?:A\$|AU\$|NZ\$|US\$|S\$|\$|€|£)?\s?-?'
  r'(\d{1,3}(?:,\d{3})+|\d+)[.,]\d{2}\s*(?:CR|-)?\W*$',
  caseSensitive: false,
);

final _labelWord = RegExp(
  r'\b(total|subtotal|sub total|gst|tax|cash|change|tendered|eftpos|'
  r'discount|rounding|refund|amount|balance|due|paid|visa|mastercard|'
  r'savings|voucher|card)\b',
);

/// Groups OCR lines into visual rows.
///
/// With geometry for every line, lines whose vertical centres lie within
/// half the smaller line height of each other share a row, read left to
/// right. Without geometry each line is a row. Afterwards a label row
/// without an amount (such as `TOTAL`) followed by a row holding only an
/// amount is merged, because engines often split right-aligned columns.
List<ReceiptRow> assembleRows(OcrResult ocr) {
  final lines = ocr.lines;
  final rows = <ReceiptRow>[];
  if (lines.isNotEmpty && lines.every((l) => l.box != null)) {
    final order = List<int>.generate(lines.length, (i) => i)
      ..sort((a, b) => lines[a].box!.centreY.compareTo(lines[b].box!.centreY));
    final groups = <List<int>>[];
    for (final index in order) {
      final box = lines[index].box!;
      final current = groups.isEmpty ? null : groups.last;
      if (current != null) {
        final anchor = lines[current.first].box!;
        final tolerance =
            (anchor.height < box.height ? anchor.height : box.height) / 2;
        if ((anchor.centreY - box.centreY).abs() <= tolerance) {
          current.add(index);
          continue;
        }
      }
      groups.add([index]);
    }
    for (final group in groups) {
      group.sort((a, b) => lines[a].box!.left.compareTo(lines[b].box!.left));
      rows.add(
        ReceiptRow(group, group.map((i) => lines[i].text.trim()).join(' ')),
      );
    }
  } else {
    for (var i = 0; i < lines.length; i++) {
      rows.add(ReceiptRow([i], lines[i].text.trim()));
    }
  }
  final merged = <ReceiptRow>[];
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (i + 1 < rows.length &&
        amountsIn(row.text).isEmpty &&
        _labelWord.hasMatch(row.lower) &&
        _amountOnly.hasMatch(rows[i + 1].text)) {
      final next = rows[i + 1];
      merged.add(
        ReceiptRow([...row.lines, ...next.lines], '${row.text} ${next.text}'),
      );
      i++;
    } else {
      merged.add(row);
    }
  }
  return merged.where((r) => r.text.isNotEmpty).toList();
}

final _cashOut = RegExp(r'\bcash\s*out\b');
final _change = RegExp(r'\bchange\b');
final _rounding = RegExp(r'\bround(ing)?\b');
final _exTax = RegExp(r'\b(ex|excl|excluding)\b\.?\s*(gst|tax)\b');
final _subtotal = RegExp(r'\bsub\s*-?\s*total\b');
final _inclusiveTax = RegExp(r'\b(inc|incl|including)\b\.?\s*(gst|tax)\b');
final _tax = RegExp(r'\b(gst|tax|vat)\b');
final _discount = RegExp(
  r'\b(discount|saving|savings|saved|less|promo|promotion|voucher|coupon|'
  r'off)\b',
);
final _charge = RegExp(
  r'\b(surcharge|tip|gratuity|delivery|shipping|postage|freight|fee)\b',
);
final _cash = RegExp(r'\b(cash|tendered|tender)\b');
final _strongTotal = RegExp(
  r'\b(total due|amount due|balance due|grand total|total payable|'
  r'amount payable|to pay|invoice total|order total|total amount|'
  r'net total|total aud|amount paid|total paid|refund total|total refund)\b',
);
final _total = RegExp(r'\btotal\b');
final refundPattern = RegExp(
  r'\b(refund|refunded|return|returned|credit note|reversal)\b',
);
final _payment = RegExp(
  r'\b(eftpos|visa|mastercard|master card|amex|american express|debit|'
  r'credit|card|paywave|paypass|contactless|apple pay|google pay|purchase|'
  r'amount|acct|payment|payments)\b',
);

/// Classifies a row by keywords, checked in this order: cash out, change,
/// rounding, ex-tax subtotal, subtotal, a total that includes tax, tax,
/// discount, extra charge, cash tendered, strong total, total, refund
/// amount (treated as a strong total), card payment, otherwise an item.
RowKind classifyRow(ReceiptRow row) {
  final t = row.lower;
  if (_cashOut.hasMatch(t)) return RowKind.cashOut;
  if (_change.hasMatch(t)) return RowKind.change;
  if (_rounding.hasMatch(t)) return RowKind.rounding;
  if (_exTax.hasMatch(t)) return RowKind.subtotal;
  if (_subtotal.hasMatch(t)) return RowKind.subtotal;
  if (_tax.hasMatch(t)) {
    final isTotal = _total.hasMatch(t) || _strongTotal.hasMatch(t);
    if (isTotal && _inclusiveTax.hasMatch(t)) return RowKind.strongTotal;
    return RowKind.tax;
  }
  if (_discount.hasMatch(t)) return RowKind.discount;
  if (_charge.hasMatch(t)) return RowKind.charge;
  if (_cash.hasMatch(t)) return RowKind.cashTendered;
  if (_strongTotal.hasMatch(t)) return RowKind.strongTotal;
  if (_total.hasMatch(t)) return RowKind.total;
  if (refundPattern.hasMatch(t)) return RowKind.strongTotal;
  if (_payment.hasMatch(t)) return RowKind.payment;
  return RowKind.item;
}

/// Currencies a receipt can name explicitly, with their exponents.
const explicitCurrencies = <String, int>{
  'AUD': 2,
  'USD': 2,
  'NZD': 2,
  'EUR': 2,
  'GBP': 2,
  'SGD': 2,
};

final _currencyTokens = <String, RegExp>{
  'AUD': RegExp(r'\bAUD\b|\bA\$|\bAU\$', caseSensitive: false),
  'USD': RegExp(r'\bUSD\b|\bUS\$', caseSensitive: false),
  'NZD': RegExp(r'\bNZD\b|\bNZ\$', caseSensitive: false),
  'EUR': RegExp(r'\bEUR\b|€', caseSensitive: false),
  'GBP': RegExp(r'\bGBP\b|£', caseSensitive: false),
  'SGD': RegExp(r'\bSGD\b|\bS\$', caseSensitive: false),
};

/// ISO codes explicitly printed on a row. A bare `$` is not explicit.
List<String> currenciesIn(String text) => [
  for (final entry in _currencyTokens.entries)
    if (entry.value.hasMatch(text)) entry.key,
];

Money money(int minor, Currency currency) => Money(minor, currency);
