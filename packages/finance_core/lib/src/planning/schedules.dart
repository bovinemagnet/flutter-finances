import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'recurrence.dart';
import 'reminders.dart';

/// What a schedule does to cash.
///
/// A transfer has explicit forecast treatment: card statement payments and
/// loan instalments reduce the paying account; only the eligible cash side
/// appears in a cash forecast (PLAN 02).
enum ScheduleKind { expense, income, transfer }

/// A recurring bill, income or transfer (PLAN 01). Scheduling never posts a
/// transaction; occurrences only become actual history when linked to a
/// journal the user confirmed.
@immutable
class RecurringSchedule {
  RecurringSchedule({
    required this.id,
    required this.name,
    required this.kind,
    required this.recurrence,
    required this.amount,
    required this.accountId,
    this.isEstimate = false,
    this.counterAccountId,
    this.categoryId,
    this.payee,
    this.reminder = const ReminderPreference(),
    this.confirmed = true,
    this.previousScheduleId,
  }) {
    if (!amount.isPositive) {
      throw ArgumentError.value(amount, 'amount', 'must be positive');
    }
    if (kind == ScheduleKind.transfer &&
        (counterAccountId == null || counterAccountId == accountId)) {
      throw ArgumentError('A transfer needs a different counter account');
    }
  }

  final String id;
  final String name;
  final ScheduleKind kind;

  /// Due dates; the start is the first due date and `until` the end date.
  final Recurrence recurrence;

  /// Expected magnitude of each occurrence.
  final Money amount;

  /// True when [amount] is an estimate, such as a variable utility bill.
  final bool isEstimate;

  /// The account paid from, or paid into for income.
  final String accountId;

  /// The receiving account of a transfer.
  final String? counterAccountId;
  final String? categoryId;
  final String? payee;
  final ReminderPreference reminder;

  /// Confirmed or user-accepted; only confirmed income counts in forecasts
  /// and the discretionary estimate.
  final bool confirmed;

  /// The schedule this one continues after a "this and future" edit.
  final String? previousScheduleId;

  /// Occurrences due within [from]..[to] inclusive after applying
  /// "this occurrence" [overrides]. Skipped occurrences are included and
  /// flagged so calendars can show them. Overrides whose original date is
  /// not an occurrence of this schedule are ignored.
  List<ScheduledOccurrence> occurrencesBetween(
    LocalDate from,
    LocalDate to, {
    Iterable<OccurrenceOverride> overrides = const [],
  }) {
    final byDate = <LocalDate, OccurrenceOverride>{
      for (final o in overrides)
        if (o.scheduleId == id && recurrence.isOccurrence(o.originalDate))
          o.originalDate: o,
    };
    final originals = {
      ...recurrence.datesBetween(from, to),
      for (final o in byDate.values)
        if (o.dueDate != null && o.dueDate! >= from && o.dueDate! <= to)
          o.originalDate,
    };
    final result = <ScheduledOccurrence>[];
    for (final original in originals) {
      final edit = byDate[original];
      final occurrence = ScheduledOccurrence(
        scheduleId: id,
        originalDate: original,
        dueDate: edit?.dueDate ?? original,
        amount: edit?.amount ?? amount,
        isEstimate: edit?.amount == null && isEstimate,
        skipped: edit?.skipped ?? false,
        overrideId: edit?.id,
      );
      if (occurrence.dueDate >= from && occurrence.dueDate <= to) {
        result.add(occurrence);
      }
    }
    result.sort((a, b) {
      final byDue = a.dueDate.compareTo(b.dueDate);
      return byDue != 0 ? byDue : a.originalDate.compareTo(b.originalDate);
    });
    return result;
  }

  /// A "this and future" edit: ends this series before [from] and starts a
  /// new schedule [newId] on [from], which must be an occurrence. The
  /// intended day of month carries over so dates do not drift; [edit] then
  /// changes the continuing schedule. Overrides of the old schedule on or
  /// after [from] no longer apply.
  ScheduleSplit splitFrom(
    LocalDate from, {
    required String newId,
    RecurringSchedule Function(RecurringSchedule continued)? edit,
  }) {
    if (!recurrence.isOccurrence(from)) {
      throw ArgumentError.value(from, 'from', 'not an occurrence');
    }
    final before = recurrence.indexOnOrBefore(from);
    final count = recurrence.count;
    final ended = copyWith(
      recurrence: recurrence.copyWith(
        until: from.addDays(-1),
        count: count == null ? null : before,
      ),
    );
    final continued = RecurringSchedule(
      id: newId,
      name: name,
      kind: kind,
      recurrence: recurrence.copyWith(
        start: from,
        dayOfMonth: recurrence.dayOfMonth,
        count: count == null ? null : count - before,
      ),
      amount: amount,
      accountId: accountId,
      isEstimate: isEstimate,
      counterAccountId: counterAccountId,
      categoryId: categoryId,
      payee: payee,
      reminder: reminder,
      confirmed: confirmed,
      previousScheduleId: id,
    );
    return ScheduleSplit(ended, edit == null ? continued : edit(continued));
  }

  RecurringSchedule copyWith({
    String? name,
    Recurrence? recurrence,
    Money? amount,
    bool? isEstimate,
    String? accountId,
    String? counterAccountId,
    String? categoryId,
    String? payee,
    ReminderPreference? reminder,
    bool? confirmed,
  }) => RecurringSchedule(
    id: id,
    name: name ?? this.name,
    kind: kind,
    recurrence: recurrence ?? this.recurrence,
    amount: amount ?? this.amount,
    accountId: accountId ?? this.accountId,
    isEstimate: isEstimate ?? this.isEstimate,
    counterAccountId: counterAccountId ?? this.counterAccountId,
    categoryId: categoryId ?? this.categoryId,
    payee: payee ?? this.payee,
    reminder: reminder ?? this.reminder,
    confirmed: confirmed ?? this.confirmed,
    previousScheduleId: previousScheduleId,
  );
}

/// The two halves of a "this and future" edit.
@immutable
class ScheduleSplit {
  const ScheduleSplit(this.ended, this.continued);

  final RecurringSchedule ended;
  final RecurringSchedule continued;
}

/// A "this occurrence" edit: move, change the amount, or skip.
@immutable
class OccurrenceOverride {
  const OccurrenceOverride({
    required this.id,
    required this.scheduleId,
    required this.originalDate,
    this.dueDate,
    this.amount,
    this.skipped = false,
  });

  final String id;
  final String scheduleId;

  /// The occurrence's date in the series, which identifies it.
  final LocalDate originalDate;
  final LocalDate? dueDate;
  final Money? amount;
  final bool skipped;
}

/// One expected occurrence. It is a plan, not a transaction.
@immutable
class ScheduledOccurrence {
  const ScheduledOccurrence({
    required this.scheduleId,
    required this.originalDate,
    required this.dueDate,
    required this.amount,
    required this.isEstimate,
    required this.skipped,
    this.overrideId,
  });

  final String scheduleId;
  final LocalDate originalDate;
  final LocalDate dueDate;
  final Money amount;
  final bool isEstimate;
  final bool skipped;
  final String? overrideId;

  /// Stable identifier: schedule id and original date.
  String get key => '$scheduleId@$originalDate';
}
