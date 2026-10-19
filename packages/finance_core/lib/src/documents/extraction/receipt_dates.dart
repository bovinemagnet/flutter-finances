import '../../time/local_date.dart';
import '../imports/date_format.dart';

/// Which part of an all-numeric date comes first.
enum DateConvention {
  /// Day before month, the Australian convention and the default.
  dayMonth,

  /// Month before day, as on many United States invoices.
  monthDay,
}

/// A date printed on a receipt row. [alternative] is the other reading of
/// an ambiguous all-numeric date (both day and month at most 12).
class PrintedDate {
  PrintedDate(this.date, {this.alternative, this.labelled = false});

  final LocalDate date;
  final LocalDate? alternative;
  final bool labelled;

  bool get ambiguous => alternative != null;
}

final _iso = RegExp(r'(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)');
final _numeric = RegExp(
  r'(?<![\d.,/-])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?![\d/]|[.,]\d)',
);
final _monthName =
    'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|'
    'aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
final _dayMonthName = RegExp(
  '(?<!\\d)(\\d{1,2})(?:st|nd|rd|th)?[\\s-]*($_monthName)\\.?,?[\\s-]*'
  '(\\d{4}|\\d{2})(?!\\d)',
  caseSensitive: false,
);
final _monthNameDay = RegExp(
  '(?<![a-z])($_monthName)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+'
  '(\\d{4})(?!\\d)',
  caseSensitive: false,
);

/// Rows whose dates are not the purchase date.
final excludedDateRow = RegExp(
  r'\b(exp|expiry|expires|valid|due|best before|use by|birth|dob|until|'
  r'period)\b',
);
final _dateLabel = RegExp(
  r'\b(date|dated|invoice date|order date|transaction date|purchased|'
  r'issued|placed)\b',
);

int _year(String text) =>
    text.length == 2 ? 2000 + int.parse(text) : int.parse(text);

LocalDate? _date(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return null;
  if (day > LocalDate.daysInMonth(year, month)) return null;
  return LocalDate(year, month, day);
}

int _month(String name) =>
    monthAbbreviations.indexOf(name.substring(0, 3).toLowerCase()) + 1;

/// Dates on one row, read with [convention] for all-numeric dates.
List<PrintedDate> datesIn(String text, DateConvention convention) {
  final lower = text.toLowerCase();
  if (excludedDateRow.hasMatch(lower)) return const [];
  final labelled = _dateLabel.hasMatch(lower);
  final found = <PrintedDate>[];
  for (final m in _iso.allMatches(text)) {
    final date = _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (date != null) found.add(PrintedDate(date, labelled: labelled));
  }
  if (found.isEmpty) {
    for (final m in _numeric.allMatches(text)) {
      final a = int.parse(m[1]!);
      final b = int.parse(m[2]!);
      final year = _year(m[3]!);
      final dayMonth = _date(year, b, a);
      final monthDay = _date(year, a, b);
      final preferred = convention == DateConvention.dayMonth
          ? dayMonth
          : monthDay;
      final other = convention == DateConvention.dayMonth ? monthDay : dayMonth;
      final chosen = preferred ?? other;
      if (chosen == null) continue;
      found.add(
        PrintedDate(
          chosen,
          alternative: preferred != null && other != null && other != preferred
              ? other
              : null,
          labelled: labelled,
        ),
      );
    }
  }
  for (final m in _dayMonthName.allMatches(text)) {
    final date = _date(_year(m[3]!), _month(m[2]!), int.parse(m[1]!));
    if (date != null) found.add(PrintedDate(date, labelled: labelled));
  }
  for (final m in _monthNameDay.allMatches(text)) {
    final date = _date(int.parse(m[3]!), _month(m[1]!), int.parse(m[2]!));
    if (date != null) found.add(PrintedDate(date, labelled: labelled));
  }
  return found;
}
