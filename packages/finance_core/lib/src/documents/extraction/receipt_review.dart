import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import '../receipts/receipt.dart';
import 'extraction.dart';

/// Where a value shown for review comes from.
enum FieldOrigin { confirmed, extracted, none }

/// One field on the review screen (REC 06, OCR 03).
@immutable
class ReviewField<T> {
  ReviewField({
    required this.value,
    required this.origin,
    this.confidence,
    Set<UncertaintyReason> reasons = const {},
    List<T> alternatives = const [],
  }) : reasons = Set.unmodifiable(reasons),
       alternatives = List.unmodifiable(alternatives);

  final T? value;
  final FieldOrigin origin;
  final ConfidenceCategory? confidence;
  final Set<UncertaintyReason> reasons;

  /// Other candidates the user can pick instead.
  final List<T> alternatives;

  /// Whether the interface should draw attention to the field: anything
  /// missing, and any extracted value that is not high confidence or has
  /// an uncertainty reason. Confirmed values are never highlighted.
  bool get highlight => switch (origin) {
    FieldOrigin.confirmed => false,
    FieldOrigin.none => true,
    FieldOrigin.extracted =>
      confidence != ConfidenceCategory.high || reasons.isNotEmpty,
  };
}

@immutable
class ReceiptReview {
  ReceiptReview({
    required this.merchant,
    required this.date,
    required this.total,
    required this.tax,
    required Set<UncertaintyReason> reviewReasons,
  }) : reviewReasons = Set.unmodifiable(reviewReasons);

  final ReviewField<String> merchant;
  final ReviewField<LocalDate> date;
  final ReviewField<Money> total;
  final ReviewField<Money> tax;

  /// Extraction-level reasons that must be visible before posting.
  final Set<UncertaintyReason> reviewReasons;
}

ReviewField<T> _field<T>(T? confirmed, List<FieldCandidate<T>> candidates) {
  final alternatives = [
    for (final c in candidates)
      if (c.value != confirmed) c.value,
  ];
  if (confirmed != null) {
    return ReviewField(
      value: confirmed,
      origin: FieldOrigin.confirmed,
      alternatives: alternatives,
    );
  }
  final best = candidates.firstOrNull;
  if (best == null) {
    return ReviewField<T>(value: null, origin: FieldOrigin.none);
  }
  return ReviewField(
    value: best.value,
    origin: FieldOrigin.extracted,
    confidence: best.confidence,
    reasons: best.reasons,
    alternatives: alternatives.skip(1).toList(),
  );
}

/// Combines the user's confirmed values with the latest [extraction] for
/// the review screen. Confirmed values always win, so rerunning extraction
/// can only add suggestions, never replace a confirmation (OCR 03).
ReceiptReview buildReceiptReview(Receipt receipt, Extraction? extraction) {
  final confirmed = receipt.confirmed;
  return ReceiptReview(
    merchant: _field(confirmed.merchant, extraction?.merchant ?? const []),
    date: _field(confirmed.date, extraction?.date ?? const []),
    total: _field(confirmed.total, extraction?.total ?? const []),
    tax: _field(confirmed.tax, extraction?.tax ?? const []),
    reviewReasons: extraction?.reviewReasons ?? const {},
  );
}
