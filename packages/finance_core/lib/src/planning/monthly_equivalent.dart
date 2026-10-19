import 'package:meta/meta.dart';

import '../money/money.dart';
import 'recurrence.dart';
import 'rounding.dart';

/// A per-month figure derived from another frequency (BUD 02).
///
/// Uses the documented annual factor `occurrencesPerYear / (12 × interval)`
/// (weekly 52/12, fortnightly 26/12, daily 365/12, quarterly 4/12, annual
/// 1/12) with half-up rounding to a minor unit. Only an exact monthly
/// amount is not an estimate.
@immutable
class MonthlyEstimate {
  const MonthlyEstimate(
    this.amount,
    this.annualFactor, {
    required this.isEstimate,
  });

  final Money amount;

  /// The factor applied, for example `52/12`, shown beside the estimate.
  final String annualFactor;
  final bool isEstimate;
}

/// Converts an amount that repeats every [interval] [frequency] units into a
/// monthly equivalent.
MonthlyEstimate monthlyEquivalent(
  Money amount,
  Frequency frequency, {
  int interval = 1,
}) {
  final numerator = frequency.occurrencesPerYear;
  final denominator = 12 * interval;
  return MonthlyEstimate(
    Money(scaleHalfUp(amount.minor, numerator, denominator), amount.currency),
    '$numerator/$denominator',
    isEstimate: numerator != denominator,
  );
}
