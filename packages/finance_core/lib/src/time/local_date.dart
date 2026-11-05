import 'package:meta/meta.dart';

/// A calendar date without time or timezone, used for financial effective
/// dates. The workspace timezone decides which [LocalDate] "today" is.
@immutable
class LocalDate implements Comparable<LocalDate> {
  LocalDate(this.year, this.month, this.day) {
    if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
      throw ArgumentError('Invalid date $year-$month-$day');
    }
  }

  /// Reads `YYYY-MM-DD`. Opening a workspace parses one of these for every
  /// entry, so this reads the digits directly (NFR 02).
  factory LocalDate.parse(String text) {
    final trimmed = text.trim();
    final year = trimmed.length == 10 ? _digits(trimmed, 0, 4) : -1;
    final month = _digits(trimmed, 5, 7);
    final day = _digits(trimmed, 8, 10);
    if (year < 0 ||
        month < 0 ||
        day < 0 ||
        trimmed.codeUnitAt(4) != _dash ||
        trimmed.codeUnitAt(7) != _dash) {
      throw FormatException('Expected YYYY-MM-DD', text);
    }
    try {
      return LocalDate(year, month, day);
    } on ArgumentError {
      throw FormatException('Invalid date', text);
    }
  }

  factory LocalDate.fromDateTime(DateTime value) =>
      LocalDate(value.year, value.month, value.day);

  final int year;
  final int month;
  final int day;

  static const _dash = 0x2d;

  /// The ASCII digits of [text] from [start] up to [end] as a number, or -1
  /// if any is missing or is not a digit.
  static int _digits(String text, int start, int end) {
    if (end > text.length) return -1;
    var value = 0;
    for (var i = start; i < end; i++) {
      final digit = text.codeUnitAt(i) - 0x30;
      if (digit < 0 || digit > 9) return -1;
      value = value * 10 + digit;
    }
    return value;
  }

  /// The length of a month. A month outside 1 to 12 counts on from [year], as
  /// `DateTime` does.
  static int daysInMonth(int year, int month) => switch (month) {
    1 || 3 || 5 || 7 || 8 || 10 || 12 => 31,
    4 || 6 || 9 || 11 => 30,
    2 => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28,
    _ => DateTime.utc(year, month + 1, 0).day,
  };

  DateTime _utc() => DateTime.utc(year, month, day);

  /// ISO weekday, Monday is 1 and Sunday is 7.
  int get weekday => _utc().weekday;

  bool get isLastDayOfMonth => day == daysInMonth(year, month);

  LocalDate addDays(int days) =>
      LocalDate.fromDateTime(DateTime.utc(year, month, day + days));

  /// Moves by whole months, clamping to the end of a shorter month.
  ///
  /// [intendedDay] keeps a schedule's original day (for example 31) so that a
  /// date clamped to 28 February returns to 31 March on the next step.
  LocalDate addMonths(int months, {int? intendedDay}) {
    final index = year * 12 + (month - 1) + months;
    final targetYear = index ~/ 12;
    final targetMonth = index % 12 + 1;
    final wanted = intendedDay ?? day;
    final last = daysInMonth(targetYear, targetMonth);
    return LocalDate(targetYear, targetMonth, wanted > last ? last : wanted);
  }

  int daysUntil(LocalDate other) => other._utc().difference(_utc()).inDays;

  bool operator <(LocalDate other) => compareTo(other) < 0;
  bool operator <=(LocalDate other) => compareTo(other) <= 0;
  bool operator >(LocalDate other) => compareTo(other) > 0;
  bool operator >=(LocalDate other) => compareTo(other) >= 0;

  @override
  int compareTo(LocalDate other) => (year * 10000 + month * 100 + day)
      .compareTo(other.year * 10000 + other.month * 100 + other.day);

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}
