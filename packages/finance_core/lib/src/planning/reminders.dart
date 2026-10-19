import 'package:meta/meta.dart';

import '../time/local_date.dart';
import 'schedules.dart';

/// When and how to remind about a scheduled item (PLAN 04).
///
/// Delivery is best effort because the operating system controls it; the
/// in-app calendar remains the authoritative record. Minutes are counted
/// from local midnight in the workspace timezone.
@immutable
class ReminderPreference {
  const ReminderPreference({
    this.enabled = true,
    this.leadDays = 1,
    this.minuteOfDay = 9 * 60,
    this.quietStartMinute,
    this.quietEndMinute,
    this.showDetails = false,
  });

  final bool enabled;
  final int leadDays;
  final int minuteOfDay;

  /// Start of quiet hours; when later than [quietEndMinute] the quiet
  /// period runs overnight.
  final int? quietStartMinute;
  final int? quietEndMinute;

  /// Notification text hides amounts and merchant details unless true.
  final bool showDetails;
}

/// A reminder to hand to the platform notification service.
@immutable
class PlannedReminder {
  const PlannedReminder({
    required this.scheduleId,
    required this.originalDate,
    required this.remindOn,
    required this.minuteOfDay,
    required this.text,
  });

  final String scheduleId;
  final LocalDate originalDate;
  final LocalDate remindOn;
  final int minuteOfDay;
  final String text;
}

/// Plans the reminder for [occurrence], moving it to the end of quiet
/// hours when it would fall inside them. Returns null when reminders are
/// off or the occurrence is skipped.
PlannedReminder? planReminder(
  RecurringSchedule schedule,
  ScheduledOccurrence occurrence,
) {
  final preference = schedule.reminder;
  if (!preference.enabled || occurrence.skipped) return null;
  final (day, minute) = applyQuietHours(
    occurrence.dueDate.addDays(-preference.leadDays),
    preference,
  );
  final due = occurrence.dueDate;
  final income = schedule.kind == ScheduleKind.income;
  final verb = income ? 'expected on' : 'due on';
  final text = preference.showDetails
      ? '${schedule.name}: ${occurrence.amount} $verb $due'
      : income
      ? 'Scheduled income is $verb $due'
      : 'A scheduled payment is $verb $due';
  return PlannedReminder(
    scheduleId: schedule.id,
    originalDate: occurrence.originalDate,
    remindOn: day,
    minuteOfDay: minute,
    text: text,
  );
}

/// The day and minute to remind on [day] at the preference's minute,
/// moved to the end of quiet hours when it would fall inside them (to the
/// next morning for overnight quiet hours).
(LocalDate, int) applyQuietHours(LocalDate day, ReminderPreference preference) {
  var minute = preference.minuteOfDay;
  final quietStart = preference.quietStartMinute;
  final quietEnd = preference.quietEndMinute;
  if (quietStart != null && quietEnd != null && quietStart != quietEnd) {
    final overnight = quietStart > quietEnd;
    final quiet = overnight
        ? minute >= quietStart || minute < quietEnd
        : minute >= quietStart && minute < quietEnd;
    if (quiet) {
      if (overnight && minute >= quietStart) day = day.addDays(1);
      minute = quietEnd;
    }
  }
  return (day, minute);
}
