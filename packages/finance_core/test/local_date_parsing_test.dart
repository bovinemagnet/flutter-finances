import 'dart:math';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

/// The definition: what a date string means, written the slow, obvious way.
LocalDate _definition(String text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text.trim());
  if (match == null) throw FormatException('Expected YYYY-MM-DD', text);
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day) {
    throw FormatException('Invalid date', text);
  }
  return LocalDate(year, month, day);
}

void main() {
  group('LocalDate.parse agrees with the definition', () {
    void same(String text) {
      Object? outcome(LocalDate Function(String) parse) {
        try {
          return parse(text).toString();
        } on FormatException catch (e) {
          return 'FormatException: ${e.message}';
        }
      }

      expect(
        outcome(LocalDate.parse),
        outcome(_definition),
        reason: 'parsing ${text.runes.toList()}',
      );
    }

    test('on awkward text', () {
      for (final text in [
        '2026-10-20',
        ' 2026-10-20 ',
        '\t2026-10-20\n',
        ' 2026-10-20 ',
        '2024-02-29',
        '2023-02-29',
        '2000-02-29',
        '1900-02-29',
        '0000-01-01',
        '9999-12-31',
        '2026-00-10',
        '2026-13-01',
        '2026-10-00',
        '2026-10-32',
        '2026-04-31',
        '',
        ' ',
        '2026',
        '2026-10',
        '2026-1-20',
        '2026-10-2',
        '2026-10-200',
        '12026-10-20',
        '2026/10/20',
        '2026-10/20',
        '20261020',
        '2026-10-2x',
        '2x26-10-20',
        '-026-10-20',
        '+026-10-20',
        '2026-+1-20',
        '2026--1-20',
        '٢٠٢٦-١٠-٢٠',
        '２０２６-１０-２０',
        '2026-10-20T00:00:00Z',
        '2026-10-20\n2026-10-21',
      ]) {
        same(text);
      }
    });

    test('on every day of many years, and on damaged copies', () {
      final random = Random(7);
      for (var day = DateTime.utc(1896); day.year < 2105;) {
        final text = day.toIso8601String().substring(0, 10);
        same(text);
        final at = random.nextInt(10);
        final char = '0123456789-/ x'[random.nextInt(14)];
        same(text.replaceRange(at, at + 1, char));
        day = DateTime.utc(day.year, day.month, day.day + 1);
      }
    });
  });

  test('daysInMonth agrees with the calendar, inside and outside 1 to 12', () {
    for (final year in [-400, -100, -4, -1, 0, 1, 4, 100, 400, 1900, 2000]) {
      for (var month = -2; month <= 26; month++) {
        expect(
          LocalDate.daysInMonth(year, month),
          DateTime.utc(year, month + 1, 0).day,
          reason: '$year-$month',
        );
      }
    }
    for (var year = 1890; year < 2110; year++) {
      for (var month = 1; month <= 12; month++) {
        expect(
          LocalDate.daysInMonth(year, month),
          DateTime.utc(year, month + 1, 0).day,
          reason: '$year-$month',
        );
      }
    }
  });
}
