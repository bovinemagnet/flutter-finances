import 'package:meta/meta.dart';

import '../../planning/reminders.dart';
import '../../time/local_date.dart';

/// A warranty carried by a receipt or one of its items (P1).
@immutable
class Warranty {
  Warranty({
    required this.id,
    required this.receiptId,
    required this.description,
    required this.startDate,
    required this.months,
    this.days = 0,
    this.itemId,
    List<int> reminderLeadDays = const [30],
    this.notes,
  }) : reminderLeadDays = List.unmodifiable(reminderLeadDays) {
    if (months < 0 || days < 0 || months + days == 0) {
      throw ArgumentError('A warranty needs a positive period');
    }
    if (reminderLeadDays.any((d) => d < 0)) {
      throw ArgumentError.value(
        reminderLeadDays,
        'reminderLeadDays',
        'must not be negative',
      );
    }
  }

  final String id;
  final String receiptId;

  /// The confirmed receipt item covered, or null for the whole receipt.
  final String? itemId;
  final String description;

  /// The first day of cover, usually the purchase date.
  final LocalDate startDate;

  /// The period: calendar months (clamped to shorter months) then days.
  final int months;
  final int days;

  /// Days before [expiresOn] to remind; 0 reminds on the last day.
  final List<int> reminderLeadDays;
  final String? notes;

  /// The last day of cover: [startDate] plus the period, less one day.
  LocalDate get expiresOn =>
      startDate.addMonths(months).addDays(days).addDays(-1);

  bool isActiveOn(LocalDate date) => date >= startDate && date <= expiresOn;
}

/// Reminders before [warranty] ends, in date order, for the platform
/// notification service (PLAN 04). They use the same [PlannedReminder]
/// and quiet-hours rule as schedule reminders: `scheduleId` holds the
/// warranty id and `originalDate` the expiry date. Text hides the item
/// unless [ReminderPreference.showDetails]. Reminders before [today] are
/// left out; none are planned when the preference is disabled.
List<PlannedReminder> warrantyReminders(
  Warranty warranty, {
  ReminderPreference preference = const ReminderPreference(),
  LocalDate? today,
}) {
  if (!preference.enabled) return const [];
  final expires = warranty.expiresOn;
  final text = preference.showDetails
      ? 'Warranty for ${warranty.description} ends on $expires'
      : 'A warranty ends on $expires';
  final reminders = <PlannedReminder>[
    for (final lead in {...warranty.reminderLeadDays})
      () {
        final (day, minute) = applyQuietHours(
          expires.addDays(-lead),
          preference,
        );
        return PlannedReminder(
          scheduleId: warranty.id,
          originalDate: expires,
          remindOn: day,
          minuteOfDay: minute,
          text: text,
        );
      }(),
  ].where((r) => today == null || r.remindOn >= today).toList();
  reminders.sort((a, b) {
    final byDay = a.remindOn.compareTo(b.remindOn);
    return byDay != 0 ? byDay : a.minuteOfDay.compareTo(b.minuteOfDay);
  });
  return reminders;
}
