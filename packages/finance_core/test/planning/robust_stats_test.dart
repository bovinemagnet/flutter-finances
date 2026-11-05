import 'dart:math';

import 'package:finance_core/src/planning/robust_stats.dart';
import 'package:test/test.dart';

/// The definition itself, doing all the sorting: four times the median and
/// four times the median absolute deviation.
({int median4, int mad4}) _bruteForce(List<int> values) {
  final sorted = [...values]..sort();
  final n = sorted.length;
  final m2 = n.isOdd ? 2 * sorted[n ~/ 2] : sorted[n ~/ 2 - 1] + sorted[n ~/ 2];
  final deviations = [for (final v in sorted) (2 * v - m2).abs()]..sort();
  final mad2Doubled = n.isOdd
      ? 2 * deviations[n ~/ 2]
      : deviations[n ~/ 2 - 1] + deviations[n ~/ 2];
  return (median4: 2 * m2, mad4: mad2Doubled);
}

void main() {
  test('the median and MAD of a sorted list match the sorting version', () {
    final random = Random(7);
    for (var round = 0; round < 2000; round++) {
      final values = [
        for (var i = 0; i < 1 + random.nextInt(40); i++)
          random.nextInt(round.isEven ? 10 : 100000) - 20,
      ];
      final sorted = [...values]..sort();
      expect(
        medianAndMadOfSorted(sorted),
        medianAndMad(values),
        reason: '$values',
      );
    }
  });

  test('worked examples', () {
    expect(medianAndMadOfSorted([5]), (median4: 20, mad4: 0));
    // Median 2.5; deviations 1.5, 0.5, 0.5, 1.5 give a MAD of 1.
    expect(medianAndMadOfSorted([1, 2, 3, 4]), (median4: 10, mad4: 4));
    expect(medianAndMadOfSorted([1, 1, 1, 50]), (median4: 4, mad4: 0));
  });

  group('the median and its deviation match the definition', () {
    test('on small lists', () {
      for (final values in [
        [5],
        [1, 2],
        [7, 7],
        [1, 2, 3],
        [1, 1, 100],
        [-5, 0, 5, 1000],
        [3, 3, 3, 3, 3],
        [0, 0, 0, 10],
      ]) {
        expect(medianAndMad(values), _bruteForce(values), reason: '$values');
      }
    });

    test('on thousands of random lists, with ties and negatives', () {
      final random = Random(42);
      for (var round = 0; round < 5000; round++) {
        final n = 1 + random.nextInt(60);
        final spread = 1 + random.nextInt(round.isEven ? 8 : 100000);
        final values = [
          for (var i = 0; i < n; i++) random.nextInt(spread) - spread ~/ 3,
        ];
        expect(medianAndMad(values), _bruteForce(values), reason: '$values');
      }
    });
  });
}
