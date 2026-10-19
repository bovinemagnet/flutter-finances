import 'package:meta/meta.dart';

import '../time/local_date.dart';

/// An inclusive range of local dates for reports and insights (REP 02).
@immutable
class DateRange {
  DateRange(this.start, this.end) {
    if (end < start) throw ArgumentError('Range ends before it starts');
  }

  /// 1 January to 31 December.
  factory DateRange.calendarYear(int year) =>
      DateRange(LocalDate(year, 1, 1), LocalDate(year, 12, 31));

  /// The Australian financial year from 1 July [startYear] to 30 June of
  /// the following year.
  factory DateRange.financialYear(int startYear) =>
      DateRange(LocalDate(startYear, 7, 1), LocalDate(startYear + 1, 6, 30));

  factory DateRange.financialYearContaining(LocalDate date) =>
      DateRange.financialYear(date.month >= 7 ? date.year : date.year - 1);

  final LocalDate start;
  final LocalDate end;

  /// `FY2026-27` for an Australian financial year, otherwise `start..end`.
  String get label {
    if (start.month == 7 &&
        start.day == 1 &&
        end == LocalDate(start.year + 1, 6, 30)) {
      final next = (start.year + 1) % 100;
      return 'FY${start.year}-${next.toString().padLeft(2, '0')}';
    }
    return '$start..$end';
  }

  bool contains(LocalDate date) => date >= start && date <= end;

  /// Calendar-month slices of this range, clipped to its ends.
  List<DateRange> months() {
    final result = <DateRange>[];
    var sliceStart = start;
    while (sliceStart <= end) {
      final monthEnd = LocalDate(
        sliceStart.year,
        sliceStart.month,
        LocalDate.daysInMonth(sliceStart.year, sliceStart.month),
      );
      final sliceEnd = monthEnd < end ? monthEnd : end;
      result.add(DateRange(sliceStart, sliceEnd));
      sliceStart = sliceEnd.addDays(1);
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '$start..$end';
}
