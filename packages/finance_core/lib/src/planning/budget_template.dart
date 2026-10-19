import 'package:meta/meta.dart';

import '../money/money.dart';
import 'rounding.dart';

/// Basis points in 100%.
const int fullShareBasisPoints = 10000;

/// A group's share of take-home income in basis points (5000 is 50%).
@immutable
class TemplateGroup {
  const TemplateGroup(this.id, this.shareBasisPoints)
    : assert(shareBasisPoints >= 0);

  final String id;
  final int shareBasisPoints;

  /// The Needs, Wants and Savings starting point (BUD 01). Users may change
  /// every percentage afterwards.
  static const fiftyThirtyTwenty = [
    TemplateGroup('needs', 5000),
    TemplateGroup('wants', 3000),
    TemplateGroup('savings', 2000),
  ];
}

/// Group amounts from a template plus the money left unassigned.
@immutable
class TemplateAllocation {
  const TemplateAllocation(this.amounts, this.unassigned);

  /// Amount per group id, in template order.
  final Map<String, Money> amounts;

  /// Income less every group amount; negative when shares exceed 100%.
  final Money unassigned;
}

/// Splits take-home [income] across [groups] by basis points (BUD 01).
///
/// The groups together receive `income × Σshares ÷ 10000`, rounded half
/// away from zero; that total is then split with [allocateByWeights], so
/// the amounts are exact and a 100% template uses every cent.
TemplateAllocation allocateTemplate(Money income, List<TemplateGroup> groups) {
  final shares = [for (final g in groups) g.shareBasisPoints];
  final shareTotal = shares.fold<int>(0, (a, b) => a + b);
  final groupTotal = scaleHalfUp(
    income.minor,
    shareTotal,
    fullShareBasisPoints,
  );
  final parts = shareTotal == 0
      ? List<int>.filled(groups.length, 0)
      : allocateByWeights(groupTotal, shares);
  return TemplateAllocation({
    for (var i = 0; i < groups.length; i++)
      groups[i].id: Money(parts[i], income.currency),
  }, income - Money(groupTotal, income.currency));
}

/// Splits a group's [amount] across categories by integer [weights], in
/// map order, using [allocateByWeights].
Map<String, Money> allocateWithinGroup(Money amount, Map<String, int> weights) {
  final ids = weights.keys.toList();
  final parts = amount.allocate([for (final id in ids) weights[id]!]);
  return {for (var i = 0; i < ids.length; i++) ids[i]: parts[i]};
}
