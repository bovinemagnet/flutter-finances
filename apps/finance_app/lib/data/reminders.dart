import 'package:finance_core/finance_core.dart';

import '../format/formatters.dart';
import '../platform/services.dart';

/// Turns schedules into local reminders (PLAN 04). Notification text hides
/// amounts and merchants unless the schedule opts in; the in-app calendar
/// stays the authoritative record because delivery is best effort.
List<Reminder> planReminders(
  Iterable<RecurringSchedule> schedules,
  Iterable<OccurrenceOverride> overrides, {
  required DateTime now,
  int horizonDays = 30,
  Iterable<Warranty> warranties = const [],
}) {
  final today = LocalDate.fromDateTime(now);
  final reminders = <Reminder>[];
  for (final schedule in schedules) {
    final lead = schedule.reminder.leadDays;
    for (final occurrence in schedule.occurrencesBetween(
      today,
      today.addDays(horizonDays + lead),
      overrides: overrides,
    )) {
      final planned = planReminder(schedule, occurrence);
      if (planned == null) continue;
      final at = DateTime(
        planned.remindOn.year,
        planned.remindOn.month,
        planned.remindOn.day,
        planned.minuteOfDay ~/ 60,
        planned.minuteOfDay % 60,
      );
      if (!at.isAfter(now)) continue;
      final due = formatDate(occurrence.dueDate);
      reminders.add(
        Reminder(
          id: _stableId(occurrence.key),
          at: at,
          title: schedule.kind == ScheduleKind.income
              ? 'Income expected'
              : 'Bill due',
          privateBody: 'Due $due. Open the app for details.',
          detailedBody:
              '${schedule.name}: ${formatMoney(occurrence.amount)} due $due',
          showDetails: schedule.reminder.showDetails,
        ),
      );
    }
  }
  final horizonEnd = now.add(Duration(days: horizonDays));
  for (final warranty in warranties) {
    for (final planned in warrantyReminders(warranty, today: today)) {
      final at = DateTime(
        planned.remindOn.year,
        planned.remindOn.month,
        planned.remindOn.day,
        planned.minuteOfDay ~/ 60,
        planned.minuteOfDay % 60,
      );
      if (!at.isAfter(now) || at.isAfter(horizonEnd)) continue;
      reminders.add(
        Reminder(
          id: _stableId('warranty:${warranty.id}@${planned.remindOn}'),
          at: at,
          title: 'Warranty ending',
          privateBody:
              'A warranty ends on ${formatDate(warranty.expiresOn)}. Open the app for details.',
          detailedBody:
              'The warranty for ${warranty.description} ends on ${formatDate(warranty.expiresOn)}',
        ),
      );
    }
  }
  reminders.sort((a, b) => a.at.compareTo(b.at));
  return reminders;
}

/// A 31-bit FNV-1a hash, so rescheduling replaces rather than duplicates.
int _stableId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Replaces all scheduled reminders with the current plan.
Future<void> syncReminders(
  Notifications notifications,
  Iterable<RecurringSchedule> schedules,
  Iterable<OccurrenceOverride> overrides, {
  required DateTime now,
  Iterable<Warranty> warranties = const [],
}) async {
  await notifications.cancelAll();
  for (final reminder in planReminders(
    schedules,
    overrides,
    now: now,
    warranties: warranties,
  )) {
    await notifications.schedule(reminder, showDetails: reminder.showDetails);
  }
}
