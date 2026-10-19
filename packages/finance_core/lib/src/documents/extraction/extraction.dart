import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import '../receipts/receipt.dart';
import 'ocr_result.dart';

/// A heuristic confidence category (OCR 03). The parser documents how each
/// category is reached; no percentage is ever derived or shown.
///
/// - [high]: the value is corroborated by independent evidence on the
///   receipt (arithmetic, a payment line, a label) and nothing competes.
/// - [medium]: found by a keyword or position but not corroborated.
/// - [low]: inferred without a keyword, or competing values exist.
enum ConfidenceCategory { high, medium, low }

/// Why a value, or the whole extraction, needs a careful look (OCR 04).
enum UncertaintyReason {
  ambiguousDate('AMBIGUOUS_DATE'),
  futureDate('FUTURE_DATE'),
  conflictingDates('CONFLICTING_DATES'),
  multiplePlausibleTotals('MULTIPLE_PLAUSIBLE_TOTALS'),
  totalInferred('TOTAL_INFERRED'),
  arithmeticMismatch('ARITHMETIC_MISMATCH'),
  currencyNotExplicit('CURRENCY_NOT_EXPLICIT'),
  foreignCurrency('FOREIGN_CURRENCY'),
  conflictingCurrencies('CONFLICTING_CURRENCIES'),
  refundReceipt('REFUND_RECEIPT'),
  merchantGuessed('MERCHANT_GUESSED'),
  taxImplausible('TAX_IMPLAUSIBLE'),
  missingMerchant('MISSING_MERCHANT'),
  missingDate('MISSING_DATE'),
  missingTotal('MISSING_TOTAL');

  const UncertaintyReason(this.code);
  final String code;
}

/// A parsed value with where it came from and how sure the parser is.
@immutable
class FieldCandidate<T> {
  FieldCandidate({
    required this.value,
    required List<int> sourceLines,
    required this.sourceText,
    required this.confidence,
    Set<UncertaintyReason> reasons = const {},
  }) : sourceLines = List.unmodifiable(sourceLines),
       reasons = Set.unmodifiable(reasons);

  final T value;

  /// Indexes into [OcrResult.lines] that produced the value.
  final List<int> sourceLines;

  /// The recognised text of those lines, joined.
  final String sourceText;
  final ConfidenceCategory confidence;
  final Set<UncertaintyReason> reasons;
}

/// Whether printed subtotal, discounts, charges, rounding and tax add up
/// to the chosen total.
enum ArithmeticCheck { consistent, inconsistent, insufficient }

/// One run of the receipt parser over an OCR result (OCR 01, OCR 03).
///
/// Candidates are ordered best first. An extraction is immutable evidence:
/// a rerun creates a new extraction and never touches the values the user
/// confirmed on the receipt.
@immutable
class Extraction {
  Extraction({
    required this.id,
    required this.receiptId,
    required this.createdAt,
    required this.ocr,
    required this.extractionVersion,
    required List<FieldCandidate<String>> merchant,
    required List<FieldCandidate<LocalDate>> date,
    required List<FieldCandidate<Money>> total,
    required List<FieldCandidate<Money>> tax,
    required List<FieldCandidate<String>> currency,
    required this.isRefund,
    required this.arithmetic,
    required Set<UncertaintyReason> reviewReasons,
    this.subtotal,
    this.cashTendered,
    this.change,
  }) : merchant = List.unmodifiable(merchant),
       date = List.unmodifiable(date),
       total = List.unmodifiable(total),
       tax = List.unmodifiable(tax),
       currency = List.unmodifiable(currency),
       reviewReasons = Set.unmodifiable(reviewReasons);

  final String id;
  final String receiptId;

  /// When the parser ran (UTC).
  final DateTime createdAt;

  /// The original engine output, including engine name and version.
  final OcrResult ocr;

  /// Version of the parsing rules that produced the candidates.
  final String extractionVersion;
  final List<FieldCandidate<String>> merchant;
  final List<FieldCandidate<LocalDate>> date;

  /// Positive magnitudes; see [isRefund] for direction.
  final List<FieldCandidate<Money>> total;
  final List<FieldCandidate<Money>> tax;

  /// ISO currency codes printed on the receipt; empty when only a bare `$`
  /// (or nothing) appears.
  final List<FieldCandidate<String>> currency;
  final FieldCandidate<Money>? subtotal;
  final FieldCandidate<Money>? cashTendered;
  final FieldCandidate<Money>? change;
  final bool isRefund;
  final ArithmeticCheck arithmetic;

  /// Reasons that require visible review before anything is posted.
  final Set<UncertaintyReason> reviewReasons;

  String get text => ocr.text;

  /// The leading candidate for each field.
  ReceiptFields get suggested => ReceiptFields(
    merchant: merchant.firstOrNull?.value,
    date: date.firstOrNull?.value,
    total: total.firstOrNull?.value,
    tax: tax.firstOrNull?.value,
    isRefund: isRefund,
  );
}
