import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_template.dart';
import 'periods.dart';

/// Needs/Wants/Savings groups, plain categories (BUD 01), or zero-based
/// (P1). Every mode uses the same versions and allocations; category-only
/// and zero-based plans have no groups.
enum BudgetMode {
  groups,
  categoryOnly,

  /// Every dollar of income is assigned to categories, goals or debt;
  /// money left unassigned is an error to fix, not a buffer. See
  /// [checkZeroBased].
  zeroBased,
}

/// Whether a zero-based plan assigns exactly its income.
enum ZeroBasedState { balanced, unassigned, overAssigned }

/// Income against everything assigned in a zero-based plan.
@immutable
class ZeroBasedCheck {
  const ZeroBasedCheck({required this.income, required this.assigned});

  final Money income;

  /// Planned amounts of every allocation (categories, goals and loan
  /// principal), plus approved adjustments when checked for a period.
  final Money assigned;

  /// `income − assigned`: positive is unassigned, negative over-assigned.
  Money get difference => income - assigned;

  ZeroBasedState get state => difference.isZero
      ? ZeroBasedState.balanced
      : difference.isPositive
      ? ZeroBasedState.unassigned
      : ZeroBasedState.overAssigned;

  /// Unassigned and over-assigned money are both errors in this mode.
  bool get isError => state != ZeroBasedState.balanced;
}

/// Checks that [version] assigns every dollar of its income (P1
/// zero-based mode). [adjustments] adds approved changes for one period.
ZeroBasedCheck checkZeroBased(BudgetVersion version, {Money? adjustments}) {
  var assigned = version.allocations.fold(
    Money.zero(version.income.currency),
    (sum, a) => sum + a.planned,
  );
  if (adjustments != null) assigned += adjustments;
  return ZeroBasedCheck(income: version.income, assigned: assigned);
}

/// A budget group such as Needs, Wants or Savings.
@immutable
class BudgetGroup {
  const BudgetGroup({
    required this.id,
    required this.name,
    required this.shareBasisPoints,
    this.discretionary = false,
  });

  final String id;
  final String name;

  /// Share of take-home income in basis points.
  final int shareBasisPoints;

  /// Whether the group's spending is discretionary (BUD 07), as Wants is.
  final bool discretionary;
}

/// What an allocation plans for.
enum AllocationTargetKind {
  /// Spending in an expense category.
  category,

  /// Money allocated to a savings goal or sinking fund (BUD 04, 05).
  goal,

  /// Principal repaid on a loan (BUD 06). Credit cards are not allowed: the
  /// purchases were already counted as spending.
  loanPrincipal,
}

/// Planned amount per period for one target.
@immutable
class BudgetAllocation {
  const BudgetAllocation({
    required this.targetKind,
    required this.targetId,
    required this.planned,
    this.groupId,
    this.rollover,
  });

  const BudgetAllocation.category(
    this.targetId,
    this.planned, {
    this.groupId,
    this.rollover,
  }) : targetKind = AllocationTargetKind.category;

  const BudgetAllocation.goal(
    this.targetId,
    this.planned, {
    this.groupId,
    this.rollover,
  }) : targetKind = AllocationTargetKind.goal;

  const BudgetAllocation.loanPrincipal(
    this.targetId,
    this.planned, {
    this.groupId,
    this.rollover,
  }) : targetKind = AllocationTargetKind.loanPrincipal;

  final AllocationTargetKind targetKind;

  /// Category, goal or loan account id.
  final String targetId;
  final Money planned;
  final String? groupId;

  /// Overrides the plan's rollover policy for this target when set.
  final RolloverPolicy? rollover;
}

/// One group's target from its share of income against what is allocated.
@immutable
class GroupAllocationSummary {
  const GroupAllocationSummary({
    required this.groupId,
    required this.target,
    required this.allocated,
  });

  final String groupId;
  final Money target;
  final Money allocated;

  Money get _difference => target - allocated;
  Money get unassigned =>
      _difference.isNegative ? Money.zero(target.currency) : _difference;
  Money get overAllocated =>
      _difference.isNegative ? -_difference : Money.zero(target.currency);
}

/// Income against allocations, with over-allocation and unassigned money
/// shown explicitly rather than netted (BUD 01).
@immutable
class AllocationSummary {
  const AllocationSummary({
    required this.income,
    required this.allocated,
    required this.groups,
    required this.shareBasisPoints,
  });

  final Money income;
  final Money allocated;
  final List<GroupAllocationSummary> groups;

  /// Total of group shares; above 10000 means shares exceed income.
  final int shareBasisPoints;

  Money get _difference => income - allocated;
  Money get unassigned =>
      _difference.isNegative ? Money.zero(income.currency) : _difference;
  Money get overAllocated =>
      _difference.isNegative ? -_difference : Money.zero(income.currency);
}

/// The allocations that apply from [effectiveFrom] until the next version.
///
/// [income] is planned take-home income per period; the application never
/// estimates tax or compulsory superannuation.
@immutable
class BudgetVersion {
  BudgetVersion({
    required this.id,
    required this.effectiveFrom,
    required this.income,
    List<BudgetGroup> groups = const [],
    List<BudgetAllocation> allocations = const [],
  }) : groups = List.unmodifiable(groups),
       allocations = List.unmodifiable(allocations) {
    final groupIds = {for (final g in groups) g.id};
    final targets = <String>{};
    for (final allocation in allocations) {
      if (allocation.groupId != null &&
          !groupIds.contains(allocation.groupId)) {
        throw ArgumentError('Unknown budget group ${allocation.groupId}');
      }
      if (!targets.add(allocation.targetId)) {
        throw ArgumentError('Duplicate allocation for ${allocation.targetId}');
      }
    }
  }

  /// Builds category allocations from group shares and category weights.
  factory BudgetVersion.fromTemplate({
    required String id,
    required LocalDate effectiveFrom,
    required Money income,
    required List<BudgetGroup> groups,
    required Map<String, Map<String, int>> categoryWeights,
  }) {
    final template = allocateTemplate(income, [
      for (final g in groups) TemplateGroup(g.id, g.shareBasisPoints),
    ]);
    return BudgetVersion(
      id: id,
      effectiveFrom: effectiveFrom,
      income: income,
      groups: groups,
      allocations: [
        for (final group in groups)
          if (categoryWeights[group.id] case final weights?
              when weights.isNotEmpty)
            for (final entry in allocateWithinGroup(
              template.amounts[group.id]!,
              weights,
            ).entries)
              BudgetAllocation.category(
                entry.key,
                entry.value,
                groupId: group.id,
              ),
      ],
    );
  }

  final String id;

  /// Start of the first period this version governs.
  final LocalDate effectiveFrom;
  final Money income;
  final List<BudgetGroup> groups;
  final List<BudgetAllocation> allocations;

  BudgetAllocation? allocationFor(String targetId) {
    for (final allocation in allocations) {
      if (allocation.targetId == targetId) return allocation;
    }
    return null;
  }

  BudgetGroup? group(String id) {
    for (final group in groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  AllocationSummary summary() {
    final zero = Money.zero(income.currency);
    final targets = allocateTemplate(income, [
      for (final g in groups) TemplateGroup(g.id, g.shareBasisPoints),
    ]).amounts;
    return AllocationSummary(
      income: income,
      allocated: allocations.fold(zero, (sum, a) => sum + a.planned),
      shareBasisPoints: groups.fold(0, (sum, g) => sum + g.shareBasisPoints),
      groups: [
        for (final group in groups)
          GroupAllocationSummary(
            groupId: group.id,
            target: targets[group.id]!,
            allocated: allocations
                .where((a) => a.groupId == group.id)
                .fold(zero, (sum, a) => sum + a.planned),
          ),
      ],
    );
  }
}

/// A budget with its period schedule and every historical version (BUD 03).
@immutable
class BudgetPlan {
  BudgetPlan({
    required this.id,
    required this.name,
    required this.mode,
    required this.schedule,
    required List<BudgetVersion> versions,
  }) : versions = List<BudgetVersion>.unmodifiable(
         <BudgetVersion>[...versions]
           ..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom)),
       ) {
    if (mode != BudgetMode.groups && versions.any((v) => v.groups.isNotEmpty)) {
      throw ArgumentError('Only group budgets have groups');
    }
  }

  final String id;
  final String name;
  final BudgetMode mode;
  final PeriodSchedule schedule;

  /// Versions ordered by [BudgetVersion.effectiveFrom].
  final List<BudgetVersion> versions;

  /// The version in force for [period], or null before the first version.
  BudgetVersion? versionFor(BudgetPeriod period) {
    BudgetVersion? found;
    for (final version in versions) {
      if (version.effectiveFrom <= period.start) found = version;
    }
    return found;
  }

  /// Adds or replaces the version starting at [version]'s effective date.
  ///
  /// Periods that ended before the period containing [today] keep their
  /// versions: such a change throws [StateError]. The effective date must be
  /// a period start.
  BudgetPlan withVersion(BudgetVersion version, {required LocalDate today}) {
    if (schedule.periodContaining(version.effectiveFrom).start !=
        version.effectiveFrom) {
      throw ArgumentError('A version must start at the start of a period');
    }
    if (version.effectiveFrom < schedule.periodContaining(today).start) {
      throw StateError('Past budget versions are retained, not rewritten');
    }
    return BudgetPlan(
      id: id,
      name: name,
      mode: mode,
      schedule: schedule,
      versions: [
        for (final existing in versions)
          if (existing.effectiveFrom != version.effectiveFrom) existing,
        version,
      ],
    );
  }
}

/// An approved change to one target's budget in one period (BUD 03).
/// Unapproved adjustments are proposals and do not affect remaining.
@immutable
class BudgetAdjustment {
  const BudgetAdjustment({
    required this.id,
    required this.planId,
    required this.targetId,
    required this.periodStart,
    required this.amount,
    this.approved = true,
    this.note,
  });

  final String id;
  final String planId;
  final String targetId;
  final LocalDate periodStart;
  final Money amount;
  final bool approved;
  final String? note;
}
