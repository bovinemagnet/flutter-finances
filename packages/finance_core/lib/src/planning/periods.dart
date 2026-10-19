import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'monthly_equivalent.dart' as monthly;
import 'recurrence.dart';

/// How a category's remaining budget carries into the next period (BUD 03).
enum RolloverPolicy {
  /// Every period starts afresh.
  none,

  /// Unspent money carries forward; overspending does not.
  positiveOnly,

  /// Unspent money and overspending both carry forward.
  signed;

  /// Opening rollover for the next period given this period's remaining.
  Money nextOpening(Money remaining) => switch (this) {
    none => Money.zero(remaining.currency),
    positiveOnly =>
      remaining.isNegative ? Money.zero(remaining.currency) : remaining,
    signed => remaining,
  };
}

/// Budget period lengths (BUD 02).
enum PeriodCycle { month, week, fortnight, custom }

/// One budget period. [end] is inclusive.
@immutable
class BudgetPeriod {
  BudgetPeriod({
    required this.start,
    required this.end,
    required this.timezone,
    this.rollover = RolloverPolicy.none,
  }) {
    if (end < start) throw ArgumentError('Period ends before it starts');
  }

  final LocalDate start;
  final LocalDate end;

  /// IANA timezone that decides which local date is "today" for the period.
  final String timezone;
  final RolloverPolicy rollover;

  int get lengthDays => start.daysUntil(end) + 1;

  bool contains(LocalDate date) => date >= start && date <= end;

  @override
  bool operator ==(Object other) =>
      other is BudgetPeriod &&
      other.start == start &&
      other.end == end &&
      other.timezone == timezone &&
      other.rollover == rollover;

  @override
  int get hashCode => Object.hash(start, end, timezone, rollover);

  @override
  String toString() => '$start..$end';
}

/// Generates contiguous budget periods from an [anchor] date.
///
/// Each period starts on an occurrence of [recurrence] and ends the day
/// before the next one. Monthly periods keep the anchor's day of month with
/// the [monthEnd] rule; fortnights advance 14 days from the anchor; custom
/// periods advance [lengthDays] days.
@immutable
class PeriodSchedule {
  PeriodSchedule({
    required this.cycle,
    required this.anchor,
    required this.timezone,
    this.lengthDays,
    this.rollover = RolloverPolicy.none,
    this.monthEnd = MonthEndRule.clamp,
  }) : recurrence = Recurrence(
         frequency: switch (cycle) {
           PeriodCycle.month => Frequency.monthly,
           PeriodCycle.week => Frequency.weekly,
           PeriodCycle.fortnight => Frequency.fortnightly,
           PeriodCycle.custom => Frequency.daily,
         },
         interval: cycle == PeriodCycle.custom ? _customLength(lengthDays) : 1,
         start: anchor,
         monthEnd: monthEnd,
       );

  static int _customLength(int? lengthDays) {
    if (lengthDays == null || lengthDays < 1) {
      throw ArgumentError.value(
        lengthDays,
        'lengthDays',
        'custom periods need a positive length',
      );
    }
    return lengthDays;
  }

  final PeriodCycle cycle;
  final LocalDate anchor;
  final String timezone;

  /// Length of a custom period in days; ignored for other cycles.
  final int? lengthDays;
  final RolloverPolicy rollover;
  final MonthEndRule monthEnd;

  /// The series of period start dates.
  final Recurrence recurrence;

  /// Period number [index], where period 0 starts on [anchor].
  BudgetPeriod periodAt(int index) => BudgetPeriod(
    start: recurrence.occurrence(index),
    end: recurrence.occurrence(index + 1).addDays(-1),
    timezone: timezone,
    rollover: rollover,
  );

  int indexOf(LocalDate date) => recurrence.indexOnOrBefore(date);

  BudgetPeriod periodContaining(LocalDate date) => periodAt(indexOf(date));

  BudgetPeriod next(BudgetPeriod period) => periodAt(indexOf(period.start) + 1);

  BudgetPeriod previous(BudgetPeriod period) =>
      periodAt(indexOf(period.start) - 1);

  /// [count] consecutive periods starting with the anchor period.
  List<BudgetPeriod> generate(int count) => [
    for (var i = 0; i < count; i++) periodAt(i),
  ];

  /// Monthly equivalent of an amount budgeted per period; an estimate for
  /// anything other than monthly periods.
  monthly.MonthlyEstimate monthlyEquivalent(Money perPeriod) =>
      monthly.monthlyEquivalent(
        perPeriod,
        recurrence.frequency,
        interval: recurrence.interval,
      );
}
