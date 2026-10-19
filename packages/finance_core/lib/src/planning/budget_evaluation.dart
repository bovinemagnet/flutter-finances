import 'package:meta/meta.dart';

import '../ledger/accounts.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_arithmetic.dart';
import 'budget_plan.dart';
import 'category_activity.dart';
import 'periods.dart';
import 'savings_allocation.dart';

/// One target's budget in one period (BUD 03).
@immutable
class BudgetLine {
  BudgetLine({
    required this.targetKind,
    required this.targetId,
    required this.groupId,
    required this.rollover,
    required this.planned,
    required this.openingRollover,
    required this.adjustments,
    required this.postedNet,
    required this.pending,
    required List<String> journalIds,
    required List<String> pendingJournalIds,
  }) : journalIds = List.unmodifiable(journalIds),
       pendingJournalIds = List.unmodifiable(pendingJournalIds),
       _result = budgetRemaining(
         planned: planned,
         openingRollover: openingRollover,
         adjustments: adjustments,
         postedNet: postedNet,
         pending: pending,
       );

  final AllocationTargetKind targetKind;
  final String targetId;
  final String? groupId;
  final RolloverPolicy rollover;
  final Money planned;
  final Money openingRollover;
  final Money adjustments;

  /// Posted spending net of refunds, money allocated to a goal, or loan
  /// principal repaid, depending on [targetKind].
  final Money postedNet;
  final Money pending;

  /// Source entries behind [postedNet] for drill-through.
  final List<String> journalIds;
  final List<String> pendingJournalIds;
  final BudgetRemaining _result;

  Money get remaining => _result.remaining;
  Money get remainingAfterPending => _result.remainingAfterPending;
}

/// Totals for a budget group such as Needs, Wants or Savings.
@immutable
class BudgetGroupLine {
  const BudgetGroupLine({
    required this.group,
    required this.planned,
    required this.actual,
    required this.pending,
    required this.remaining,
    required this.remainingAfterPending,
  });

  final BudgetGroup group;
  String get groupId => group.id;
  final Money planned;
  final Money actual;
  final Money pending;
  final Money remaining;
  final Money remainingAfterPending;
}

/// A budget period's lines, group totals and unbudgeted spending.
@immutable
class BudgetPeriodEvaluation {
  BudgetPeriodEvaluation({
    required this.period,
    required this.version,
    required List<BudgetLine> lines,
    required List<BudgetLine> unbudgeted,
    required List<BudgetGroupLine> groups,
  }) : lines = List.unmodifiable(lines),
       unbudgeted = List.unmodifiable(unbudgeted),
       groups = List.unmodifiable(groups);

  final BudgetPeriod period;

  /// The version in force, or null when the period predates the plan.
  final BudgetVersion? version;
  final List<BudgetLine> lines;

  /// Expense categories with activity but no allocation (planned zero).
  final List<BudgetLine> unbudgeted;
  final List<BudgetGroupLine> groups;

  AllocationSummary? get summary => version?.summary();

  BudgetLine? line(String targetId) {
    for (final line in lines) {
      if (line.targetId == targetId) return line;
    }
    return null;
  }

  BudgetGroupLine? group(String groupId) {
    for (final group in groups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }
}

/// Evaluates a [BudgetPlan] against the ledger period by period.
///
/// Rollover starts at zero in the first period of the first version and is
/// carried forward with each line's policy. Periods are cached, so
/// evaluating consecutive periods is linear.
class BudgetEvaluator {
  BudgetEvaluator({
    required this.plan,
    required LedgerProjection ledger,
    Iterable<BudgetAdjustment> adjustments = const [],
    Iterable<SavingsAllocation> savingsAllocations = const [],
  }) : _chart = ledger.chart,
       _index = CategoryActivityIndex.fromLedger(ledger),
       _adjustments = [
         for (final a in adjustments)
           if (a.approved && a.planId == plan.id) a,
       ],
       _savings = List.of(savingsAllocations);

  final BudgetPlan plan;
  final Chart _chart;
  final CategoryActivityIndex _index;
  final List<BudgetAdjustment> _adjustments;
  final List<SavingsAllocation> _savings;
  final Map<int, BudgetPeriodEvaluation> _cache = {};

  Money get _zero => Money.zero(_chart.currency);

  BudgetPeriodEvaluation evaluateAt(LocalDate date) =>
      _evaluate(plan.schedule.indexOf(date));

  BudgetPeriodEvaluation evaluate(BudgetPeriod period) =>
      _evaluate(plan.schedule.indexOf(period.start));

  BudgetPeriodEvaluation _evaluate(int index) {
    final cached = _cache[index];
    if (cached != null) return cached;
    final first = plan.versions.isEmpty
        ? index
        : plan.schedule.indexOf(plan.versions.first.effectiveFrom);
    var start = index;
    while (start > first && !_cache.containsKey(start - 1)) {
      start--;
    }
    for (var k = start; k <= index; k++) {
      _cache[k] = _compute(k, k > first ? _cache[k - 1] : null);
    }
    return _cache[index]!;
  }

  BudgetPeriodEvaluation _compute(int index, BudgetPeriodEvaluation? previous) {
    final period = plan.schedule.periodAt(index);
    final version = plan.versionFor(period);
    final lines = [
      for (final allocation
          in version?.allocations ?? const <BudgetAllocation>[])
        _line(allocation, period, previous?.line(allocation.targetId)),
    ];
    final budgeted = {for (final l in lines) l.targetId};
    final unbudgeted = [
      for (final id in _index.activeCategories(period.start, period.end))
        if (!budgeted.contains(id) &&
            _chart.category(id).kind == CategoryKind.expense)
          _line(BudgetAllocation.category(id, _zero), period, null),
    ];
    return BudgetPeriodEvaluation(
      period: period,
      version: version,
      lines: lines,
      unbudgeted: unbudgeted,
      groups: [
        for (final group in version?.groups ?? const <BudgetGroup>[])
          _groupLine(group, lines.where((l) => l.groupId == group.id)),
      ],
    );
  }

  BudgetLine _line(
    BudgetAllocation allocation,
    BudgetPeriod period,
    BudgetLine? previous,
  ) {
    final id = allocation.targetId;
    final from = period.start;
    final to = period.end;
    var posted = _zero;
    var pending = _zero;
    var ids = const <String>[];
    var pendingIds = const <String>[];
    switch (allocation.targetKind) {
      case AllocationTargetKind.category:
        posted = _index.net(id, from, to);
        pending = _index.net(id, from, to, pending: true);
        ids = _index.journalIds(id, from, to);
        pendingIds = _index.journalIds(id, from, to, pending: true);
      case AllocationTargetKind.goal:
        final inPeriod = _savings.where(
          (s) => s.goalId == id && period.contains(s.date),
        );
        posted = inPeriod.fold(_zero, (sum, s) => sum + s.amount);
        ids = [
          for (final s in inPeriod)
            if (s.transferJournalId != null) s.transferJournalId!,
        ];
      case AllocationTargetKind.loanPrincipal:
        if (_chart.account(id).type != AccountType.loan) {
          throw ArgumentError(
            'Only loans can be debt-reduction targets; card purchases are '
            'already counted as spending',
          );
        }
        posted = _index.principalRepaid(id, from, to);
        ids = _index.principalJournalIds(id, from, to);
    }
    return BudgetLine(
      targetKind: allocation.targetKind,
      targetId: id,
      groupId: allocation.groupId,
      rollover: allocation.rollover ?? plan.schedule.rollover,
      planned: allocation.planned,
      openingRollover: previous == null
          ? _zero
          : previous.rollover.nextOpening(previous.remaining),
      adjustments: _adjustments
          .where((a) => a.targetId == id && a.periodStart == from)
          .fold(_zero, (sum, a) => sum + a.amount),
      postedNet: posted,
      pending: pending,
      journalIds: ids,
      pendingJournalIds: pendingIds,
    );
  }

  BudgetGroupLine _groupLine(BudgetGroup group, Iterable<BudgetLine> lines) {
    Money total(Money Function(BudgetLine) pick) =>
        lines.fold(_zero, (sum, l) => sum + pick(l));
    return BudgetGroupLine(
      group: group,
      planned: total((l) => l.planned),
      actual: total((l) => l.postedNet),
      pending: total((l) => l.pending),
      remaining: total((l) => l.remaining),
      remainingAfterPending: total((l) => l.remainingAfterPending),
    );
  }
}
