import 'package:meta/meta.dart';

import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_evaluation.dart';
import 'budget_plan.dart';
import 'forecast.dart';
import 'payments.dart';
import 'reservations.dart';
import 'savings_allocation.dart';
import 'schedules.dart';

/// The explainable discretionary spending estimate (BUD 07).
@immutable
class DiscretionaryEstimate {
  DiscretionaryEstimate({
    required this.budgetLimit,
    required this.cashLimit,
    required this.discretionaryRemaining,
    required this.unpostedCommitments,
    required this.minimumBuffer,
    required this.forecast,
    required this.sourceFreshness,
    required List<String> missingInputs,
  }) : missingInputs = List.unmodifiable(missingInputs);

  /// Remaining discretionary budget after pending purchases and unposted
  /// discretionary commitments; null when there is no budget.
  final Money? budgetLimit;

  /// Lowest projected eligible cash over the horizon less the buffer.
  final Money cashLimit;
  final Money? discretionaryRemaining;
  final Money? unpostedCommitments;
  final Money minimumBuffer;
  final CashForecast forecast;

  /// Oldest "data complete to" date among eligible accounts.
  final LocalDate? sourceFreshness;

  /// Inputs that are missing or stale; the result is incomplete if any.
  final List<String> missingInputs;

  /// The smaller limit, never below zero.
  Money get estimate => combineLimits(budgetLimit, cashLimit).$1;

  /// How far the smaller limit is below zero, shown beside the estimate.
  Money get shortfall => combineLimits(budgetLimit, cashLimit).$2;

  bool get complete => missingInputs.isEmpty;
  LocalDate get horizonStart => forecast.start;
  LocalDate get horizonEnd => forecast.end;
  Money get lowestBalance => forecast.lowestBalance;
  LocalDate get lowestBalanceDate => forecast.lowestDate;
}

/// Displayed estimate and shortfall: the smaller limit (the cash limit
/// alone without a budget) clamped at zero, and its magnitude when
/// negative.
(Money, Money) combineLimits(Money? budgetLimit, Money cashLimit) {
  final smaller = budgetLimit != null && budgetLimit < cashLimit
      ? budgetLimit
      : cashLimit;
  final zero = Money.zero(cashLimit.currency);
  return smaller.isNegative ? (zero, -smaller) : (smaller, zero);
}

/// Estimates discretionary spending available from [today] to [horizonEnd]
/// (normally the day before the next selected payday), following BUD 07:
///
/// * Budget limit: Σ remaining-after-pending of discretionary targets in
///   the budget period containing today, less the outstanding amount of
///   confirmed expense occurrences in those categories due from today to
///   the earlier of [horizonEnd] and the period end. Pending card purchases
///   count because category pending ignores the paying account.
/// * Cash limit: the lowest closing balance of [buildCashForecast] over the
///   horizon less [minimumBuffer]. Only confirmed income is projected, and
///   reservations in excluded accounts are not subtracted.
/// * A linked occurrence that is posted is consumed in both limits.
///
/// Discretionary targets default to allocations in groups flagged
/// discretionary. Missing inputs are `budget`, `minimumBuffer`,
/// `accountData:<id>` (no freshness date) and `staleAccountData:<id>`
/// (older than [staleAfterDays] before today), per eligible account in id
/// order, followed by [additionalMissingInputs].
DiscretionaryEstimate estimateDiscretionary({
  required BudgetPlan? plan,
  required LedgerProjection ledger,
  required LocalDate today,
  required LocalDate horizonEnd,
  Iterable<RecurringSchedule> schedules = const [],
  Iterable<OccurrenceOverride> overrides = const [],
  Iterable<OccurrencePayment> payments = const [],
  Iterable<Reservation> reservations = const [],
  Iterable<BudgetAdjustment> adjustments = const [],
  Iterable<SavingsAllocation> savingsAllocations = const [],
  Money? minimumBuffer,
  Map<String, LocalDate> accountDataAsOf = const {},
  int staleAfterDays = 3,
  Set<String>? discretionaryTargetIds,
  List<String> additionalMissingInputs = const [],
}) {
  final currency = ledger.chart.currency;
  final zero = Money.zero(currency);
  final missing = <String>[];
  final scheduleList = schedules.toList();
  final paymentList = payments.toList();

  final forecast = buildCashForecast(
    ledger: ledger,
    today: today,
    end: horizonEnd,
    schedules: scheduleList,
    overrides: overrides,
    payments: paymentList,
    reservations: reservations,
  );

  Money? remaining;
  Money? commitments;
  final evaluation = plan == null
      ? null
      : BudgetEvaluator(
          plan: plan,
          ledger: ledger,
          adjustments: adjustments,
          savingsAllocations: savingsAllocations,
        ).evaluateAt(today);
  final version = evaluation?.version;
  final targets =
      discretionaryTargetIds ??
      {
        for (final line in evaluation?.lines ?? const <BudgetLine>[])
          if (line.groupId != null &&
              (version?.group(line.groupId!)?.discretionary ?? false))
            line.targetId,
      };
  if (evaluation == null || version == null || targets.isEmpty) {
    missing.add('budget');
  } else {
    remaining = evaluation.lines
        .where((l) => targets.contains(l.targetId))
        .fold<Money>(zero, (sum, l) => sum + l.remainingAfterPending);
    final statuses = {for (final j in ledger.journals) j.id: j.status};
    final until = horizonEnd < evaluation.period.end
        ? horizonEnd
        : evaluation.period.end;
    var committed = zero;
    for (final schedule in scheduleList) {
      if (schedule.kind != ScheduleKind.expense ||
          !schedule.confirmed ||
          !targets.contains(schedule.categoryId)) {
        continue;
      }
      for (final occurrence in schedule.occurrencesBetween(
        today,
        until,
        overrides: overrides,
      )) {
        committed += assessOccurrence(
          occurrence,
          payments: paymentList,
          journalStatuses: statuses,
          today: today,
        ).outstanding;
      }
    }
    commitments = committed;
  }

  if (minimumBuffer == null) missing.add('minimumBuffer');
  final buffer = minimumBuffer ?? zero;
  final staleBefore = today.addDays(-staleAfterDays);
  LocalDate? freshness;
  for (final id in forecast.accountIds.toList()..sort()) {
    final asOf = accountDataAsOf[id];
    if (asOf == null) {
      missing.add('accountData:$id');
      continue;
    }
    if (asOf < staleBefore) missing.add('staleAccountData:$id');
    if (freshness == null || asOf < freshness) freshness = asOf;
  }
  missing.addAll(additionalMissingInputs);

  return DiscretionaryEstimate(
    budgetLimit: remaining == null ? null : remaining - commitments!,
    cashLimit: forecast.lowestBalance - buffer,
    discretionaryRemaining: remaining,
    unpostedCommitments: commitments,
    minimumBuffer: buffer,
    forecast: forecast,
    sourceFreshness: freshness,
    missingInputs: missing,
  );
}
