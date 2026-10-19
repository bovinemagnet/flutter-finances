// Exact robust statistics over integer minor units, shared by the
// detection rules. Medians of an even count fall between two values, so
// the helpers work with doubled values and never use floating point.

/// Twice the median of [values] (which must not be empty): twice the middle
/// value, or the sum of the two middle values.
int twiceMedian(List<int> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd ? 2 * sorted[mid] : sorted[mid - 1] + sorted[mid];
}

/// [value] divided by a positive [divisor], rounded half away from zero.
int divideRounded(int value, int divisor) {
  final magnitude = (value.abs() * 2 + divisor) ~/ (2 * divisor);
  return value < 0 ? -magnitude : magnitude;
}

/// The median and median absolute deviation of [values], each scaled by
/// four so that both stay whole numbers.
({int median4, int mad4}) medianAndMad(List<int> values) {
  final m2 = twiceMedian(values);
  // |2v - 2M| doubled once more by twiceMedian gives 4 × MAD.
  final mad4 = twiceMedian([for (final v in values) (2 * v - m2).abs()]);
  return (median4: 2 * m2, mad4: mad4);
}

/// Whether [value] is unusually high against [history] by the modified
/// z-score of Iglewicz and Hoaglin: `0.6745 × (x − median) ÷ MAD > 3.5`,
/// evaluated exactly as `6745 × (x − median) > 35000 × MAD`.
///
/// The MAD is raised to at least a tenth of the median and at least one
/// minor unit, so a history of identical amounts does not make every small
/// change look unusual. The value must also exceed the median by at least
/// [minimumExcess] minor units.
bool isUnusuallyHigh(int value, List<int> history, {int minimumExcess = 0}) {
  final (:median4, :mad4) = medianAndMad(history);
  final floor4 = median4 > 0 ? (median4 + 9) ~/ 10 : 0;
  final spread4 = [mad4, floor4, 4].reduce((a, b) => a > b ? a : b);
  final excess4 = 4 * value - median4;
  if (excess4 < 4 * minimumExcess) return false;
  return BigInt.from(6745) * BigInt.from(excess4) >
      BigInt.from(35000) * BigInt.from(spread4);
}
