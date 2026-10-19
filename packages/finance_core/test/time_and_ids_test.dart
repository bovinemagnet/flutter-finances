import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  group('LocalDate', () {
    test('parses and prints ISO dates', () {
      final date = LocalDate.parse('2026-01-31');
      expect(date, LocalDate(2026, 1, 31));
      expect(date.toString(), '2026-01-31');
    });

    test('rejects impossible dates', () {
      expect(() => LocalDate(2026, 2, 29), throwsArgumentError);
      expect(() => LocalDate.parse('2026-13-01'), throwsFormatException);
    });

    test('adds days across month and year boundaries', () {
      expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
      expect(LocalDate(2026, 3, 1).addDays(-1), LocalDate(2026, 2, 28));
      expect(LocalDate(2026, 1, 1).daysUntil(LocalDate(2026, 12, 31)), 364);
    });

    test('adds months keeping the intended day with an end of month clamp', () {
      final jan31 = LocalDate(2026, 1, 31);
      expect(jan31.addMonths(1), LocalDate(2026, 2, 28));
      expect(jan31.addMonths(2), LocalDate(2026, 3, 31));
      expect(LocalDate(2028, 1, 31).addMonths(1), LocalDate(2028, 2, 29));
      expect(LocalDate(2026, 3, 15).addMonths(-3), LocalDate(2025, 12, 15));
    });

    test('orders dates and reports the weekday', () {
      expect(LocalDate(2026, 1, 1) < LocalDate(2026, 1, 2), isTrue);
      expect(LocalDate(2026, 10, 19).weekday, DateTime.monday);
    });
  });

  group('newId', () {
    test('produces unique version 7 UUIDs that sort by creation time', () {
      final ids = List.generate(500, (_) => newId());
      expect(ids.toSet().length, 500);
      for (final id in ids) {
        expect(
          id,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
      }
      final sorted = [...ids]..sort();
      expect(sorted, ids);
    });
  });
}
