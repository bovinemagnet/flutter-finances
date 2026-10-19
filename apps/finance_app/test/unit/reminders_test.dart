import 'package:finance_app/data/reminders.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  final rent = RecurringSchedule(
    id: 'rent',
    name: 'Rent',
    kind: ScheduleKind.expense,
    recurrence: Recurrence(
      frequency: Frequency.fortnightly,
      start: LocalDate(2026, 10, 12),
    ),
    amount: Money(90000, Currency.aud),
    accountId: 'bank',
    payee: 'Harbour Realty',
    reminder: const ReminderPreference(leadDays: 2),
  );

  test('plans private reminders for the next 30 days with stable ids', () {
    final now = DateTime(2026, 10, 19, 8);
    final reminders = planReminders(
      [rent],
      const [],
      now: now,
      horizonDays: 30,
    );
    expect(reminders.map((r) => r.at), [
      DateTime(2026, 10, 24, 9),
      DateTime(2026, 11, 7, 9),
    ]);
    expect(reminders.first.privateBody, isNot(contains('900')));
    expect(reminders.first.privateBody, isNot(contains('Harbour')));
    final again = planReminders([rent], const [], now: now, horizonDays: 30);
    expect(again.map((r) => r.id), reminders.map((r) => r.id));
  });

  test('skipped occurrences and past reminder times are not scheduled', () {
    final skip = OccurrenceOverride(
      id: 'o1',
      scheduleId: 'rent',
      originalDate: LocalDate(2026, 10, 26),
      skipped: true,
    );
    final reminders = planReminders(
      [rent],
      [skip],
      now: DateTime(2026, 10, 24, 10),
      horizonDays: 30,
    );
    // 26 October is skipped; 24 October 09:00 has passed.
    expect(reminders.map((r) => r.at), [
      DateTime(2026, 11, 7, 9),
      DateTime(2026, 11, 21, 9),
    ]);
  });
}
