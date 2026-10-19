import '../../time/local_date.dart';

const monthAbbreviations = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

final _formatCache = <String, (RegExp, List<String>)>{};
final _token = RegExp(r'yyyy|yy|MMM|MM|M|dd|d');

/// Parses [text] with a date [format] built from these tokens:
///
/// - `yyyy` four-digit year; `yy` two-digit year in 2000-2099.
/// - `MMM` English three-letter month, any case.
/// - `MM` or `M` month and `dd` or `d` day, each one or two digits.
///
/// Other characters must match literally. Surrounding whitespace is
/// ignored, as is anything after whitespace following the date (such as a
/// time). Returns null when the text does not match or the date does not
/// exist.
LocalDate? parseDateWithFormat(String text, String format) {
  final (pattern, tokens) = _formatCache.putIfAbsent(format, () {
    final buffer = StringBuffer('^');
    final tokens = <String>[];
    var last = 0;
    for (final match in _token.allMatches(format)) {
      buffer.write(RegExp.escape(format.substring(last, match.start)));
      final token = match[0]!;
      tokens.add(token);
      buffer.write(switch (token) {
        'yyyy' => r'(\d{4})',
        'yy' => r'(\d{2})',
        'MMM' => r'([A-Za-z]{3})',
        _ => r'(\d{1,2})',
      });
      last = match.end;
    }
    buffer.write(RegExp.escape(format.substring(last)));
    buffer.write(r'(?:\s.*)?$');
    return (RegExp(buffer.toString()), tokens);
  });
  final match = pattern.firstMatch(text.trim());
  if (match == null) return null;
  int? year;
  int? month;
  int? day;
  for (var i = 0; i < tokens.length; i++) {
    final value = match[i + 1]!;
    switch (tokens[i]) {
      case 'yyyy':
        year = int.parse(value);
      case 'yy':
        year = 2000 + int.parse(value);
      case 'MMM':
        final index = monthAbbreviations.indexOf(value.toLowerCase());
        if (index < 0) return null;
        month = index + 1;
      case 'MM' || 'M':
        month = int.parse(value);
      default:
        day = int.parse(value);
    }
  }
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1) return null;
  if (day > LocalDate.daysInMonth(year, month)) return null;
  return LocalDate(year, month, day);
}
