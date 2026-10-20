import 'package:finance_core/finance_core.dart';

/// Posted spending through a budget period against an even daily pace of
/// the period's category budget. Presentation only: the budget itself is
/// evaluated by [BudgetEvaluator].
class SpendingPace {
  SpendingPace({
    required this.period,
    required List<Money> spentByDay,
    required this.budget,
  }) : spentByDay = List.unmodifiable(spentByDay);

  final BudgetPeriod period;

  /// Cumulative posted spending at the end of each day from the period
  /// start up to today (or the period end, if earlier).
  final List<Money> spentByDay;

  /// Planned category spending plus rollover and approved adjustments.
  final Money budget;

  Money get spent => spentByDay.last;

  /// The budget spread evenly over the period, at the end of day
  /// [dayIndex] (0 is the first day).
  Money paceAt(int dayIndex) => Money(
    budget.minor * (dayIndex + 1) ~/ period.lengthDays,
    budget.currency,
  );

  Money get paceToday => paceAt(spentByDay.length - 1);
}

SpendingPace spendingPace(
  BudgetPeriodEvaluation evaluation,
  LedgerProjection ledger,
  LocalDate today,
) {
  final period = evaluation.period;
  final last = today > period.end ? period.end : today;
  final days = period.start.daysUntil(last) + 1;
  final daily = List<int>.filled(days < 0 ? 0 : days, 0);
  final chart = ledger.chart;
  for (final journal in ledger.journals) {
    if (!journal.status.inPostedLedger) continue;
    final date = journal.effectiveDate;
    if (date < period.start || date > last) continue;
    for (final posting in journal.postings) {
      if (chart.kindOf(posting.ledgerAccountId) == LedgerKind.expense) {
        daily[period.start.daysUntil(date)] += posting.amount.minor;
      }
    }
  }
  final currency = chart.currency;
  var running = 0;
  var budget = 0;
  for (final line in evaluation.lines) {
    if (line.targetKind != AllocationTargetKind.category) continue;
    budget +=
        line.planned.minor +
        line.openingRollover.minor +
        line.adjustments.minor;
  }
  return SpendingPace(
    period: period,
    spentByDay: [for (final minor in daily) Money(running += minor, currency)],
    budget: Money(budget, currency),
  );
}
