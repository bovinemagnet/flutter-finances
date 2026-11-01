// Exact robust statistics over integer minor units, shared by the
// detection rules. Medians of an even count fall between two values, so
// the helpers work with doubled values and never use floating point.

/// [value] divided by a positive [divisor], rounded half away from zero.
int divideRounded(int value, int divisor) {
  final magnitude = (value.abs() * 2 + divisor) ~/ (2 * divisor);
  return value < 0 ? -magnitude : magnitude;
}

/// The median and median absolute deviation of [values], each scaled by
/// four so that both stay whole numbers.
({int median4, int mad4}) medianAndMad(List<int> values) =>
    medianAndMadOfSorted([...values]..sort());

/// [medianAndMad] of [sorted], which must be non-empty and in ascending
/// order, in linear time and without sorting.
({int median4, int mad4}) medianAndMadOfSorted(List<int> sorted) {
  final n = sorted.length;
  final mid = n ~/ 2;
  final m2 = n.isOdd ? 2 * sorted[mid] : sorted[mid - 1] + sorted[mid];
  // The deviations |2v - 2M| grow outwards from the median, so merging the
  // values below it (walking down) with those from it (walking up) yields
  // them in ascending order.
  var right = 0;
  var high = n;
  while (right < high) {
    final m = (right + high) >> 1;
    if (2 * sorted[m] < m2) {
      right = m + 1;
    } else {
      high = m;
    }
  }
  var left = right - 1;
  int next() {
    if (left < 0 ||
        (right < n && 2 * sorted[right] - m2 <= m2 - 2 * sorted[left])) {
      return 2 * sorted[right++] - m2;
    }
    return m2 - 2 * sorted[left--];
  }

  // Twice the median of the deviations gives 4 × MAD.
  var previous = 0;
  for (var k = 0; k < mid; k++) {
    previous = next();
  }
  final middle = next();
  return (median4: 2 * m2, mad4: n.isOdd ? 2 * middle : previous + middle);
}

/// Whether [value] is unusually high against [history] by the modified
/// z-score of Iglewicz and Hoaglin: `0.6745 × (x − median) ÷ MAD > 3.5`,
/// evaluated exactly as `6745 × (x − median) > 35000 × MAD`.
///
/// The MAD is raised to at least a tenth of the median and at least one
/// minor unit, so a history of identical amounts does not make every small
/// change look unusual. The value must also exceed the median by at least
/// [minimumExcess] minor units.
bool isUnusuallyHigh(int value, List<int> history, {int minimumExcess = 0}) =>
    exceedsSpread(value, medianAndMad(history), minimumExcess: minimumExcess);

/// [isUnusuallyHigh] against the history's [medianAndMad], already worked
/// out.
bool exceedsSpread(
  int value,
  ({int median4, int mad4}) stats, {
  int minimumExcess = 0,
}) {
  final (:median4, :mad4) = stats;
  final floor4 = median4 > 0 ? (median4 + 9) ~/ 10 : 0;
  final spread4 = [mad4, floor4, 4].reduce((a, b) => a > b ? a : b);
  final excess4 = 4 * value - median4;
  if (excess4 < 4 * minimumExcess) return false;
  return BigInt.from(6745) * BigInt.from(excess4) >
      BigInt.from(35000) * BigInt.from(spread4);
}
