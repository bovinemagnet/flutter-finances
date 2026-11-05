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
/// order, in logarithmic time and without sorting or copying.
({int median4, int mad4}) medianAndMadOfSorted(List<int> sorted) {
  final n = sorted.length;
  final mid = n ~/ 2;
  final m2 = n.isOdd ? 2 * sorted[mid] : sorted[mid - 1] + sorted[mid];
  // The deviations |2v - 2M| grow outwards from the median: walking up from
  // it gives one ascending run, walking down gives another.
  var split = 0;
  var high = n;
  while (split < high) {
    final m = (split + high) >> 1;
    if (2 * sorted[m] < m2) {
      split = m + 1;
    } else {
      high = m;
    }
  }
  final upCount = n - split;
  final downCount = split;
  int up(int i) => 2 * sorted[split + i] - m2;
  int down(int i) => m2 - 2 * sorted[split - 1 - i];

  // The [k]th smallest (from zero) of both runs together: find how many of
  // the first k + 1 come from the upward run.
  int kth(int k) {
    var low = k + 1 > downCount ? k + 1 - downCount : 0;
    var top = k + 1 < upCount ? k + 1 : upCount;
    while (low < top) {
      final i = (low + top) >> 1;
      if (up(i) < down(k - i)) {
        low = i + 1;
      } else {
        top = i;
      }
    }
    final fromUp = low;
    final fromDown = k + 1 - fromUp;
    if (fromUp == 0) return down(fromDown - 1);
    if (fromDown == 0) return up(fromUp - 1);
    final a = up(fromUp - 1);
    final b = down(fromDown - 1);
    return a > b ? a : b;
  }

  // Twice the median of the deviations gives 4 × MAD.
  final middle = kth(mid);
  return (median4: 2 * m2, mad4: n.isOdd ? 2 * middle : kth(mid - 1) + middle);
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
