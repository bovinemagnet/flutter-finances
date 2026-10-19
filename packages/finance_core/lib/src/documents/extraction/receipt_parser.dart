import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import '../text/normalise.dart';
import 'extraction.dart';
import 'ocr_result.dart';
import 'receipt_dates.dart';
import 'receipt_lines.dart';

/// Version of the parsing rules, stored on every extraction (OCR 03).
const receiptParserVersion = 'receipt-parser/1';

@immutable
class ParserSettings {
  const ParserSettings({
    this.workspaceCurrency = Currency.aud,
    this.dateConvention = DateConvention.dayMonth,
    this.merchantDateConventions = const {},
    this.referenceDate,
  });

  /// Currency assumed when the receipt does not name one.
  final Currency workspaceCurrency;

  /// Reading of all-numeric dates; day-month by default (Australia).
  final DateConvention dateConvention;

  /// Conventions the user chose for particular merchants, keyed by
  /// [normaliseMerchant] of the merchant name. A merchant convention
  /// resolves ambiguity; the workspace default only orders the readings.
  final Map<String, DateConvention> merchantDateConventions;

  /// Today in the workspace timezone, used to spot future dates.
  final LocalDate? referenceDate;
}

/// Parses recognised receipt text into field candidates (OCR 01).
///
/// Extracts merchant, receipt date, total, explicit currency and printed
/// tax with provenance. Heuristics, documented for review:
///
/// - **Rows** are rebuilt from geometry when every line has a box, and a
///   label row followed by an amount-only row is merged.
/// - **Amounts** need exactly two decimal places; percentages, unit
///   quantities and dates are ignored. The last amount on a row counts.
/// - **Totals** come from rows labelled total. Cash tendered, change and
///   cash-out rows are never totals (A06). Each distinct value scores 8
///   when subtotal less discounts plus charges and rounding (plus tax when
///   tax is exclusive) equals it, 6 when a card payment row shows it, 6
///   when cash less change equals it, 2 for a strong label (`total due`,
///   `amount due`, ...), 1 when printed more than once, 1 when it is the
///   last total row; the best score wins, ties going to the lower row.
///   Confidence is high when corroborated and unchallenged, medium for a
///   label alone, low when competing totals or a mismatch exist. Without a
///   total row the total is inferred from a payment row, then cash less
///   change, then the subtotal, then the largest amount, and is marked
///   [UncertaintyReason.totalInferred].
/// - **Dates** prefer labelled rows and skip due, expiry and validity
///   dates. An all-numeric date with both parts at most 12 is ambiguous
///   unless the merchant has a chosen convention; the other reading is
///   kept as an alternative, and a reading in the future gives way to one
///   that is not.
/// - **Merchant** is a labelled value (`Sold by:`, `Merchant:`, ...) with
///   high confidence, otherwise the first heading-like row with medium
///   confidence.
/// - **Currency** is reported only when printed as a code or prefixed
///   symbol such as `AUD`, `A$` or `US$`; a bare `$` is not explicit.
Extraction parseReceipt(
  OcrResult ocr, {
  required String id,
  required String receiptId,
  required DateTime createdAt,
  ParserSettings settings = const ParserSettings(),
}) {
  final rows = assembleRows(ocr);
  final reasons = <UncertaintyReason>{};

  // Currency.
  final currencyRows = <String, ReceiptRow>{};
  for (final row in rows) {
    for (final code in currenciesIn(row.text)) {
      currencyRows.putIfAbsent(code, () => row);
    }
  }
  final currencies = [
    for (final entry in currencyRows.entries)
      _candidate(
        entry.key,
        entry.value,
        currencyRows.length == 1
            ? ConfidenceCategory.high
            : ConfidenceCategory.low,
        {if (currencyRows.length > 1) UncertaintyReason.conflictingCurrencies},
      ),
  ];
  final explicit = currencies.firstOrNull?.value;
  final currency =
      explicit == null || explicit == settings.workspaceCurrency.code
      ? settings.workspaceCurrency
      : Currency(explicit, explicitCurrencies[explicit] ?? 2);
  if (currencies.isEmpty) reasons.add(UncertaintyReason.currencyNotExplicit);
  if (currencyRows.length > 1) {
    reasons.add(UncertaintyReason.conflictingCurrencies);
  }
  if (explicit != null && explicit != settings.workspaceCurrency.code) {
    reasons.add(UncertaintyReason.foreignCurrency);
  }

  final merchant = _merchant(rows);
  if (merchant.isEmpty) reasons.add(UncertaintyReason.missingMerchant);

  final amounts = _Amounts(rows);
  final totals = amounts.totals(currency);
  final isRefund = amounts.isRefund;
  if (totals.isEmpty) reasons.add(UncertaintyReason.missingTotal);
  if (isRefund) reasons.add(UncertaintyReason.refundReceipt);
  final total = totals.firstOrNull;
  if (total != null) reasons.addAll(total.reasons);
  final tax = amounts.taxes(currency, total?.value);
  if (tax.firstOrNull?.reasons.contains(UncertaintyReason.taxImplausible) ??
      false) {
    reasons.add(UncertaintyReason.taxImplausible);
  }

  final merchantKey = merchant.isEmpty
      ? null
      : normaliseMerchant(merchant.first.value);
  final dates = _dates(rows, settings, merchantKey);
  if (dates.isEmpty) reasons.add(UncertaintyReason.missingDate);
  if (dates.isNotEmpty) reasons.addAll(dates.first.reasons);

  return Extraction(
    id: id,
    receiptId: receiptId,
    createdAt: createdAt.toUtc(),
    ocr: ocr,
    extractionVersion: receiptParserVersion,
    merchant: merchant,
    date: dates,
    total: totals,
    tax: tax,
    currency: currencies,
    subtotal: amounts.single(RowKind.subtotal, currency, last: true),
    cashTendered: amounts.single(RowKind.cashTendered, currency),
    change: amounts.single(RowKind.change, currency),
    isRefund: isRefund,
    arithmetic: amounts.arithmeticFor(total),
    reviewReasons: reasons,
  );
}

FieldCandidate<T> _candidate<T>(
  T value,
  ReceiptRow row,
  ConfidenceCategory confidence, [
  Set<UncertaintyReason> reasons = const {},
]) => FieldCandidate(
  value: value,
  sourceLines: row.lines,
  sourceText: row.text,
  confidence: confidence,
  reasons: reasons,
);

// Merchant ---------------------------------------------------------------

final _merchantLabel = RegExp(
  r'^\s*(?:sold by|merchant|supplier|seller|vendor|from|invoice from|'
  r'issued by|billed by|business name)\s*[:\-]?\s+(.+)$',
  caseSensitive: false,
);
final _welcome = RegExp(r'^\s*welcome\s+to\s+', caseSensitive: false);
final _notMerchant = RegExp(
  r'^(tax invoice|invoice|receipt|customer copy|merchant copy|'
  r'cardholder copy|eftpos|thank|thanks|abn|acn|ph\b|phone|tel\b|fax|'
  r'email|www\.|http|order|table|date|time|cashier|operator|register|'
  r'store\s*(?:no|#|\d)|trans|docket|copy|duplicate|reprint|page|tax\b|'
  r'gst|total|sub|welcome$|paid|approved|terminal|tid\b|mid\b)',
  caseSensitive: false,
);
final _decoration = RegExp(r'^[\s*#=~_|.:\-]+|[\s*#=~_|.:\-]+$');
final _letters = RegExp('[A-Za-z]');

List<FieldCandidate<String>> _merchant(List<ReceiptRow> rows) {
  for (final row in rows) {
    final match = _merchantLabel.firstMatch(row.text);
    if (match != null) {
      final value = match[1]!.replaceAll(_decoration, '');
      if (_letters.allMatches(value).length >= 2) {
        return [_candidate(value, row, ConfidenceCategory.high)];
      }
    }
  }
  final limit = rows.length < 8 ? rows.length : 8;
  for (var i = 0; i < limit; i++) {
    final row = rows[i];
    final text = row.text
        .replaceFirst(_welcome, '')
        .replaceAll(_decoration, '');
    if (_letters.allMatches(text).length < 3) continue;
    // Addresses and phone numbers start with a number and a space; names
    // such as 7-ELEVEN or 13CABS do not.
    if (RegExp(r'^\d+[\s,/]').hasMatch(text)) continue;
    // Runs of dots or question marks are illegible recognition.
    if (RegExp(r'[.?]{3,}').hasMatch(text)) continue;
    if (_notMerchant.hasMatch(text)) continue;
    if (amountsIn(text).isNotEmpty) continue;
    if (datesIn(text, DateConvention.dayMonth).isNotEmpty) continue;
    return [
      _candidate(text, row, ConfidenceCategory.medium, {
        UncertaintyReason.merchantGuessed,
      }),
    ];
  }
  return const [];
}

// Dates ------------------------------------------------------------------

List<FieldCandidate<LocalDate>> _dates(
  List<ReceiptRow> rows,
  ParserSettings settings,
  String? merchantKey,
) {
  final merchantConvention = merchantKey == null
      ? null
      : settings.merchantDateConventions[merchantKey];
  final convention = merchantConvention ?? settings.dateConvention;
  final found = <(PrintedDate, ReceiptRow)>[];
  for (final row in rows) {
    for (final date in datesIn(row.text, convention)) {
      found.add((date, row));
    }
  }
  if (found.isEmpty) return const [];
  // Labelled dates first, otherwise reading order (the sort is stable).
  final ordered = [
    ...found.where((f) => f.$1.labelled),
    ...found.where((f) => !f.$1.labelled),
  ];
  final (first, firstRow) = ordered.first;
  var primary = first.date;
  var alternative = first.alternative;
  final reference = settings.referenceDate;
  if (alternative != null &&
      reference != null &&
      primary > reference &&
      alternative <= reference) {
    (primary, alternative) = (alternative, primary);
  }
  final reasons = <UncertaintyReason>{};
  var confidence = ConfidenceCategory.high;
  if (alternative != null && merchantConvention == null) {
    reasons.add(UncertaintyReason.ambiguousDate);
    confidence = ConfidenceCategory.low;
  } else if (alternative != null) {
    confidence = ConfidenceCategory.medium;
  }
  final others = <LocalDate>[];
  for (final (date, _) in ordered.skip(1)) {
    if (date.date != primary &&
        date.date != alternative &&
        !others.contains(date.date)) {
      others.add(date.date);
    }
  }
  final competing = ordered
      .skip(1)
      .any((f) => f.$1.labelled == first.labelled && f.$1.date != first.date);
  if (competing) {
    reasons.add(UncertaintyReason.conflictingDates);
    if (confidence == ConfidenceCategory.high) {
      confidence = ConfidenceCategory.medium;
    }
  }
  if (reference != null && primary > reference) {
    reasons.add(UncertaintyReason.futureDate);
    confidence = ConfidenceCategory.low;
  }
  return [
    _candidate(primary, firstRow, confidence, reasons),
    if (alternative != null && merchantConvention == null)
      _candidate(alternative, firstRow, ConfidenceCategory.low, {
        UncertaintyReason.ambiguousDate,
      }),
    for (final other in others)
      _candidate(
        other,
        ordered.firstWhere((f) => f.$1.date == other).$2,
        ConfidenceCategory.low,
      ),
  ];
}

// Amounts ----------------------------------------------------------------

class _Valued {
  _Valued(this.index, this.row, this.kind, this.amount);

  final int index;
  final ReceiptRow row;
  final RowKind kind;
  final PrintedAmount amount;

  int get value => amount.minor;
}

class _Group {
  _Group(this.value);

  final int value;
  final rows = <_Valued>[];
  var arithmetic = false;
  var corroborated = false;
  var score = 0;

  int get lastIndex => rows.last.index;
}

class _Amounts {
  _Amounts(List<ReceiptRow> rows) {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (refundPattern.hasMatch(row.lower)) _refundWords = true;
      final found = amountsIn(row.text);
      if (found.isEmpty) continue;
      valued.add(_Valued(i, row, classifyRow(row), found.last));
    }
  }

  final valued = <_Valued>[];
  var _refundWords = false;

  Iterable<_Valued> of(RowKind kind) => valued.where((v) => v.kind == kind);

  Iterable<_Valued> get totalRows => valued.where(
    (v) => v.kind == RowKind.total || v.kind == RowKind.strongTotal,
  );

  bool get isRefund => _refundWords || totalRows.any((v) => v.amount.negative);

  int? get _cash => of(RowKind.cashTendered).firstOrNull?.value;
  int? get _change => of(RowKind.change).firstOrNull?.value;
  int? get _tax => of(RowKind.tax).firstOrNull?.value;

  /// Subtotal adjusted by what is printed between it and [totalIndex], or
  /// null when no subtotal precedes the total.
  int? _base(int totalIndex) {
    final subtotal = valued.lastWhereOrNull(
      (v) => v.kind == RowKind.subtotal && v.index < totalIndex,
    );
    if (subtotal == null) return null;
    var base = subtotal.value;
    for (final v in valued) {
      if (v.index <= subtotal.index || v.index >= totalIndex) continue;
      switch (v.kind) {
        case RowKind.discount:
          base -= v.value;
        case RowKind.charge:
          base += v.value;
        case RowKind.rounding:
          base += v.amount.negative ? -v.value : v.value;
        default:
      }
    }
    return base;
  }

  bool? _adds(int value, int totalIndex) {
    final base = _base(totalIndex);
    if (base == null) return null;
    final tax = _tax;
    return base == value || (tax != null && base + tax == value);
  }

  bool _cashChangeMatches(int value) {
    final cash = _cash;
    final change = _change;
    return cash != null && change != null && cash - change == value;
  }

  List<FieldCandidate<Money>> totals(Currency currency) {
    final groups = <int, _Group>{};
    // A zero total (such as a balance due after payment) is never the
    // amount of the purchase.
    for (final row in totalRows.where((r) => r.value != 0)) {
      groups.putIfAbsent(row.value, () => _Group(row.value)).rows.add(row);
    }
    if (groups.isEmpty) return _inferred(currency);
    final lastValue = totalRows.lastWhere((r) => r.value != 0).value;
    final payments = of(RowKind.payment).map((v) => v.value).toSet();
    for (final group in groups.values) {
      group.arithmetic = group.rows.any(
        (r) => _adds(group.value, r.index) ?? false,
      );
      final payment = payments.contains(group.value);
      final cashChange = _cashChangeMatches(group.value);
      group.corroborated = group.arithmetic || payment || cashChange;
      group.score =
          (group.arithmetic ? 8 : 0) +
          (payment ? 6 : 0) +
          (cashChange ? 6 : 0) +
          (group.rows.any((r) => r.kind == RowKind.strongTotal) ? 2 : 0) +
          (group.rows.length > 1 ? 1 : 0) +
          (group.value == lastValue ? 1 : 0);
    }
    final ranked = groups.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : b.lastIndex.compareTo(a.lastIndex);
      });
    final primary = ranked.first;
    final competing =
        ranked.length > 1 &&
        !(primary.corroborated && ranked.skip(1).every((g) => !g.corroborated));
    final reasons = <UncertaintyReason>{
      if (competing) UncertaintyReason.multiplePlausibleTotals,
      if (isRefund) UncertaintyReason.refundReceipt,
    };
    final adds = _adds(primary.value, primary.lastIndex);
    final cash = _cash;
    final change = _change;
    final mismatch =
        adds == false ||
        (cash != null && change != null && cash - change != primary.value);
    if (mismatch) reasons.add(UncertaintyReason.arithmeticMismatch);
    final confidence = competing || mismatch
        ? ConfidenceCategory.low
        : primary.corroborated
        ? ConfidenceCategory.high
        : ConfidenceCategory.medium;
    return [
      _money(primary, currency, confidence, reasons),
      for (final other in ranked.skip(1))
        _money(other, currency, ConfidenceCategory.low, {
          if (competing) UncertaintyReason.multiplePlausibleTotals,
        }),
    ];
  }

  FieldCandidate<Money> _money(
    _Group group,
    Currency currency,
    ConfidenceCategory confidence,
    Set<UncertaintyReason> reasons,
  ) {
    final row = group.rows.last.row;
    return _candidate(Money(group.value, currency), row, confidence, reasons);
  }

  List<FieldCandidate<Money>> _inferred(Currency currency) {
    final reasons = {
      UncertaintyReason.totalInferred,
      if (isRefund) UncertaintyReason.refundReceipt,
    };
    FieldCandidate<Money> from(
      int value,
      ReceiptRow row,
      ConfidenceCategory confidence,
    ) => _candidate(Money(value, currency), row, confidence, reasons);

    final payment = of(RowKind.payment).lastOrNull;
    if (payment != null) {
      return [from(payment.value, payment.row, ConfidenceCategory.medium)];
    }
    final cash = of(RowKind.cashTendered).firstOrNull;
    final change = of(RowKind.change).firstOrNull;
    if (cash != null && change != null && cash.value > change.value) {
      return [
        _candidate(
          Money(cash.value - change.value, currency),
          ReceiptRow([
            ...cash.row.lines,
            ...change.row.lines,
          ], '${cash.row.text}\n${change.row.text}'),
          ConfidenceCategory.medium,
          reasons,
        ),
      ];
    }
    final subtotal = of(RowKind.subtotal).lastOrNull;
    if (subtotal != null) {
      return [from(subtotal.value, subtotal.row, ConfidenceCategory.low)];
    }
    final items = of(RowKind.item).toList();
    if (items.isEmpty) return const [];
    final largest = items.reduce((a, b) => b.value > a.value ? b : a);
    return [from(largest.value, largest.row, ConfidenceCategory.low)];
  }

  List<FieldCandidate<Money>> taxes(Currency currency, Money? total) {
    final seen = <int, List<_Valued>>{};
    for (final row in of(RowKind.tax)) {
      seen.putIfAbsent(row.value, () => []).add(row);
    }
    final result = <FieldCandidate<Money>>[];
    for (final entry in seen.entries) {
      final first = result.isEmpty;
      final reasons = <UncertaintyReason>{};
      var confidence = first
          ? ConfidenceCategory.medium
          : ConfidenceCategory.low;
      if (first && total != null) {
        final gst = (total.minor + 5) ~/ 11;
        if (entry.key >= total.minor) {
          reasons.add(UncertaintyReason.taxImplausible);
          confidence = ConfidenceCategory.low;
        } else if (entry.value.length > 1 || (entry.key - gst).abs() <= 1) {
          confidence = ConfidenceCategory.high;
        }
      }
      result.add(
        _candidate(
          Money(entry.key, currency),
          entry.value.first.row,
          confidence,
          reasons,
        ),
      );
    }
    return result;
  }

  FieldCandidate<Money>? single(
    RowKind kind,
    Currency currency, {
    bool last = false,
  }) {
    final rows = of(kind);
    final row = last ? rows.lastOrNull : rows.firstOrNull;
    return row == null
        ? null
        : _candidate(
            Money(row.value, currency),
            row.row,
            ConfidenceCategory.medium,
          );
  }

  ArithmeticCheck arithmeticFor(FieldCandidate<Money>? total) {
    if (total == null) return ArithmeticCheck.insufficient;
    final row = totalRows.lastWhereOrNull((v) => v.value == total.value.minor);
    if (row == null) return ArithmeticCheck.insufficient;
    return switch (_adds(total.value.minor, row.index)) {
      null => ArithmeticCheck.insufficient,
      true => ArithmeticCheck.consistent,
      false => ArithmeticCheck.inconsistent,
    };
  }
}

extension<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    T? found;
    for (final item in this) {
      if (test(item)) found = item;
    }
    return found;
  }
}
