import 'package:meta/meta.dart';

import '../money/money.dart';

/// Remaining budget for one target in one period (BUD 03).
@immutable
class BudgetRemaining {
  const BudgetRemaining(this.remaining, this.remainingAfterPending);

  /// Planned + opening rollover + approved adjustments − posted net.
  final Money remaining;

  /// [remaining] less pending spending, shown separately.
  final Money remainingAfterPending;
}

/// Applies the BUD 03 formula. [postedNet] and [pending] are signed so that
/// spending is positive and refunds reduce them.
BudgetRemaining budgetRemaining({
  required Money planned,
  required Money openingRollover,
  required Money adjustments,
  required Money postedNet,
  required Money pending,
}) {
  final remaining = planned + openingRollover + adjustments - postedNet;
  return BudgetRemaining(remaining, remaining - pending);
}
