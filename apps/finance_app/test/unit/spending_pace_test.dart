import 'package:finance_app/features/overview/spending_pace.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sample_world.dart';

void main() {
  final world = SampleWorld();

  test('cumulative posted spending matches the ledger day by day', () {
    final pace = spendingPace(world.evaluation(), world.ledger, world.today);
    final start = LocalDate(2026, 10, 1);
    expect(pace.spentByDay, hasLength(19));
    for (var i = 0; i < pace.spentByDay.length; i++) {
      expect(
        pace.spentByDay[i],
        world.ledger.expenses(start, start.addDays(i)),
        reason: 'day ${i + 1}',
      );
    }
    expect(pace.spentByDay[1].minor, 0);
    expect(pace.spentByDay[2].minor, 45000);
    // The $25 pending dining entry is not spending yet.
    expect(pace.spent.minor, 77000);
  });

  test('budget is the period allocation, paced evenly by whole days', () {
    final pace = spendingPace(world.evaluation(), world.ledger, world.today);
    expect(pace.budget.minor, 280000);
    expect(pace.paceAt(30).minor, 280000);
    expect(pace.paceToday.minor, 280000 * 19 ~/ 31);
  });

  test('a date after the period shows the whole period', () {
    final pace = spendingPace(
      world.evaluation(),
      world.ledger,
      LocalDate(2026, 11, 20),
    );
    expect(pace.spentByDay, hasLength(31));
    expect(pace.spent.minor, 77000);
  });
}
