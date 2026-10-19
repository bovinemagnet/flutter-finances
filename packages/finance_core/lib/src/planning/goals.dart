import 'package:meta/meta.dart';

import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_template.dart';
import 'recurrence.dart';
import 'reservations.dart';
import 'savings_allocation.dart';

/// A savings goal, or a sinking fund for an irregular expense.
enum GoalKind { savings, sinkingFund }

/// A goal with a target, optional target date and linked account, and
/// planned contributions (BUD 04, 05).
@immutable
class Goal {
  const Goal({
    required this.id,
    required this.name,
    required this.target,
    this.kind = GoalKind.savings,
    this.targetDate,
    this.linkedAccountId,
    this.categoryId,
    this.plannedContribution,
    this.contributionFrequency,
    this.archived = false,
  });

  final String id;
  final String name;
  final GoalKind kind;
  final Money target;
  final LocalDate? targetDate;

  /// The account where the goal's money is kept, when there is one.
  final String? linkedAccountId;

  /// The expense category a sinking fund pays for.
  final String? categoryId;
  final Money? plannedContribution;
  final Frequency? contributionFrequency;
  final bool archived;
}

/// Where a goal stands: what is allocated, moved and reserved.
@immutable
class GoalProgress {
  const GoalProgress({
    required this.goal,
    required this.allocated,
    required this.moved,
    required this.reserved,
    required this.unfundedReservation,
    required this.allocationIds,
    required this.journalIds,
  });

  final Goal goal;

  /// Counted toward the Savings plan by allocation records.
  final Money allocated;

  /// Allocated amounts whose transfer is in the posted ledger.
  final Money moved;

  /// Confirmed reservations backed by money.
  final Money reserved;

  /// Reservations for this goal that no money backs.
  final Money unfundedReservation;
  final List<String> allocationIds;

  /// Posted transfers behind [moved], for drill-through.
  final List<String> journalIds;

  Money get _zero => Money.zero(goal.target.currency);
  Money _atLeastZero(Money value) => value.isNegative ? _zero : value;

  /// Allocated but not yet transferred.
  Money get notYetMoved => allocated - moved;

  /// Target less allocations, never negative.
  Money get remainingToTarget => _atLeastZero(goal.target - allocated);

  /// Target less funded reservations, never negative (BUD 05).
  Money get fundingGap => _atLeastZero(goal.target - reserved);

  /// Allocated share of the target in basis points, rounded down and
  /// capped at 10000.
  int get allocatedBasisPoints {
    if (!goal.target.isPositive || !allocated.isPositive) return 0;
    final share =
        BigInt.from(allocated.minor) *
        BigInt.from(fullShareBasisPoints) ~/
        BigInt.from(goal.target.minor);
    return share.toInt() > fullShareBasisPoints
        ? fullShareBasisPoints
        : share.toInt();
  }
}

/// Summarises [goal] from its allocations, the ledger and reservations.
GoalProgress goalProgress(
  Goal goal, {
  required LedgerProjection ledger,
  Iterable<SavingsAllocation> allocations = const [],
  ReservationAssessment? reservations,
}) {
  final zero = Money.zero(goal.target.currency);
  final statuses = {for (final j in ledger.journals) j.id: j.status};
  var allocated = zero;
  var moved = zero;
  final allocationIds = <String>[];
  final journalIds = <String>[];
  for (final allocation in allocations.where((a) => a.goalId == goal.id)) {
    allocated += allocation.amount;
    allocationIds.add(allocation.id);
    final journalId = allocation.transferJournalId;
    if (journalId != null && (statuses[journalId]?.inPostedLedger ?? false)) {
      moved += allocation.amount;
      journalIds.add(journalId);
    }
  }
  return GoalProgress(
    goal: goal,
    allocated: allocated,
    moved: moved,
    reserved: reservations?.fundedForGoal(goal.id) ?? zero,
    unfundedReservation: reservations?.unfundedForGoal(goal.id) ?? zero,
    allocationIds: allocationIds,
    journalIds: journalIds,
  );
}
