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

  factory LocalDate.parse(String text) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text.trim());
    if (match == null) throw FormatException('Expected YYYY-MM-DD', text);
    try {
      return LocalDate(
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3]!),
      );
    } on ArgumentError {
      throw FormatException('Invalid date', text);
    }
  }

  factory LocalDate.fromDateTime(DateTime value) =>
      LocalDate(value.year, value.month, value.day);

  final int year;
  final int month;
  final int day;

  static int daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

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
