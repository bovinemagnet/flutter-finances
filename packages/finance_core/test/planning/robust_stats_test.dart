import 'dart:math';

import 'package:finance_core/src/planning/robust_stats.dart';
import 'package:test/test.dart';

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
}
