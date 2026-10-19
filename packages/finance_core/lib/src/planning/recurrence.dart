import 'package:meta/meta.dart';

import '../time/local_date.dart';

/// Repeat units for schedules and budget periods (PLAN 01, BUD 02).
///
/// Day-based units advance by a fixed number of days; month-based units
/// advance by whole calendar months, so a month is never four weeks.
/// [occurrencesPerYear] is the documented annual factor used for monthly
/// equivalents.
enum Frequency {
  daily(days: 1, occurrencesPerYear: 365),
  weekly(days: 7, occurrencesPerYear: 52),
  fortnightly(days: 14, occurrencesPerYear: 26),
  monthly(months: 1, occurrencesPerYear: 12),
  quarterly(months: 3, occurrencesPerYear: 4),
  annually(months: 12, occurrencesPerYear: 1);

  const Frequency({
    this.days = 0,
    this.months = 0,
    required this.occurrencesPerYear,
  });

  /// Days per step for day-based units, otherwise zero.
  final int days;

  /// Months per step for month-based units, otherwise zero.
  final int months;
  final int occurrencesPerYear;

  bool get isMonthBased => months > 0;
}

/// The explicit end-of-month rule for month-based repeats.
enum MonthEndRule {
  /// Keep the start's day of month; in shorter months use the last day, then
  /// return to the intended day when the month is long enough again.
  clamp,

  /// Always fall on the last day of the month. The start must be a month end.
  lastDay,
}

/// A repeating series of local dates.
///
/// Occurrence `n` is computed directly from [start] (never from the previous
/// occurrence), so clamping in a short month cannot make later dates drift.
@immutable
class Recurrence {
  Recurrence({
    required this.frequency,
    required this.start,
    this.interval = 1,
    this.until,
    this.count,
    this.monthEnd = MonthEndRule.clamp,
    int? dayOfMonth,
  }) : dayOfMonth = dayOfMonth ?? start.day {
    if (interval < 1) {
      throw ArgumentError.value(interval, 'interval', 'must be at least 1');
    }
    if (count != null && count! < 0) {
      throw ArgumentError.value(count, 'count', 'must not be negative');
    }
    if (monthEnd == MonthEndRule.lastDay &&
        (!frequency.isMonthBased || !start.isLastDayOfMonth)) {
      throw ArgumentError(
        'The last-day rule needs a month-based frequency starting on a month end',
      );
    }
    if (this.dayOfMonth < 1 ||
        this.dayOfMonth > 31 ||
        (frequency.isMonthBased &&
            monthEnd == MonthEndRule.clamp &&
            start.addMonths(0, intendedDay: this.dayOfMonth) != start)) {
      throw ArgumentError(
        'The start must be the intended day ${this.dayOfMonth}, clamped to '
        'its month',
      );
    }
  }

  final Frequency frequency;
  final LocalDate start;

  /// Number of [frequency] units between occurrences (custom intervals).
  final int interval;

  /// Last date an occurrence may fall on (inclusive).
  final LocalDate? until;

  /// Maximum number of occurrences.
  final int? count;
  final MonthEndRule monthEnd;

  /// The intended day of month for month-based repeats with the clamp rule.
  /// Defaults to the start's day; a series continued from a clamped date
  /// (28 February for a 31st) keeps 31 so later dates do not drift.
  final int dayOfMonth;

  bool get isBounded => until != null || count != null;

  /// The unbounded `n`th date of the series; `n` may be negative to step
  /// backwards from [start] (used for budget periods before an anchor).
  LocalDate occurrence(int n) {
    if (!frequency.isMonthBased) {
      return start.addDays(n * interval * frequency.days);
    }
    final months = n * interval * frequency.months;
    if (monthEnd == MonthEndRule.lastDay) {
      final first = LocalDate(start.year, start.month, 1).addMonths(months);
      return LocalDate(
        first.year,
        first.month,
        LocalDate.daysInMonth(first.year, first.month),
      );
    }
    return start.addMonths(months, intendedDay: dayOfMonth);
  }

  /// Index of the last unbounded occurrence on or before [date]; negative
  /// when [date] is before [start].
  int indexOnOrBefore(LocalDate date) {
    if (!frequency.isMonthBased) {
      final step = interval * frequency.days;
      return _floorDiv(start.daysUntil(date), step);
    }
    final monthsApart =
        (date.year * 12 + date.month) - (start.year * 12 + start.month);
    var index = _floorDiv(monthsApart, interval * frequency.months);
    while (occurrence(index) > date) {
      index--;
    }
    while (occurrence(index + 1) <= date) {
      index++;
    }
    return index;
  }

  /// Whether [date] is an occurrence of this series within its bounds.
  bool isOccurrence(LocalDate date) {
    final n = indexOnOrBefore(date);
    return occurrence(n) == date && _inBounds(n, date);
  }

  bool _inBounds(int n, LocalDate date) =>
      n >= 0 &&
      (count == null || n < count!) &&
      (until == null || date <= until!);

  /// Occurrences within [from]..[to] inclusive, honouring [until] and
  /// [count].
  List<LocalDate> datesBetween(LocalDate from, LocalDate to) {
    final result = <LocalDate>[];
    final first = indexOnOrBefore(from);
    for (var n = first < 0 ? 0 : first; ; n++) {
      final date = occurrence(n);
      if (date > to || !_inBounds(n, date)) break;
      if (date >= from) result.add(date);
    }
    return result;
  }

  /// Every occurrence of a bounded series.
  List<LocalDate> dates() {
    if (!isBounded) throw StateError('An unbounded series has no end');
    final result = <LocalDate>[];
    for (var n = 0; ; n++) {
      final date = occurrence(n);
      if (!_inBounds(n, date)) break;
      result.add(date);
    }
    return result;
  }

  Recurrence copyWith({
    Frequency? frequency,
    LocalDate? start,
    int? interval,
    LocalDate? until,
    bool clearUntil = false,
    int? count,
    bool clearCount = false,
    MonthEndRule? monthEnd,
    int? dayOfMonth,
  }) => Recurrence(
    frequency: frequency ?? this.frequency,
    start: start ?? this.start,
    interval: interval ?? this.interval,
    until: clearUntil ? null : until ?? this.until,
    count: clearCount ? null : count ?? this.count,
    monthEnd: monthEnd ?? this.monthEnd,
    dayOfMonth: dayOfMonth ?? (start == null ? this.dayOfMonth : null),
  );

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.frequency == frequency &&
      other.start == start &&
      other.interval == interval &&
      other.until == until &&
      other.count == count &&
      other.monthEnd == monthEnd &&
      other.dayOfMonth == dayOfMonth;

  @override
  int get hashCode => Object.hash(
    frequency,
    start,
    interval,
    until,
    count,
    monthEnd,
    dayOfMonth,
  );
}

int _floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}
