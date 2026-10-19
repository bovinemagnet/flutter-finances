import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_plan.dart';
import 'goals.dart';
import 'insights.dart';
import 'payments.dart';
import 'periods.dart';
import 'recurrence.dart';
import 'reminders.dart';
import 'reservations.dart';
import 'savings_allocation.dart';
import 'schedules.dart';

// JSON formats for persisted and synchronised planning entities. Keys are
// camelCase, money is integer minor units in `...Minor` fields of the
// workspace currency, dates are ISO `YYYY-MM-DD` strings, enums use their
// names and absent optional values are null.

String? _date(LocalDate? date) => date?.toString();
LocalDate? _parseDate(Object? text) =>
    text == null ? null : LocalDate.parse(text as String);
LocalDate _requireDate(Object? text) => LocalDate.parse(text as String);
Money? _money(Object? minor, Currency currency) =>
    minor == null ? null : Money(minor as int, currency);
Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();
List<Map<String, Object?>> _list(Object? value) => [
  for (final item in (value as List? ?? const [])) _map(item),
];

Map<String, Object?> periodScheduleToJson(PeriodSchedule schedule) => {
  'cycle': schedule.cycle.name,
  'anchor': schedule.anchor.toString(),
  'lengthDays': schedule.cycle == PeriodCycle.custom
      ? schedule.lengthDays
      : null,
  'timezone': schedule.timezone,
  'rollover': schedule.rollover.name,
  'monthEnd': schedule.monthEnd.name,
};

PeriodSchedule periodScheduleFromJson(
  Map<String, Object?> json,
) => PeriodSchedule(
  cycle: PeriodCycle.values.byName(json['cycle'] as String),
  anchor: _requireDate(json['anchor']),
  lengthDays: json['lengthDays'] as int?,
  timezone: json['timezone'] as String,
  rollover: RolloverPolicy.values.byName(json['rollover'] as String? ?? 'none'),
  monthEnd: MonthEndRule.values.byName(json['monthEnd'] as String? ?? 'clamp'),
);

Map<String, Object?> budgetVersionToJson(BudgetVersion version) => {
  'id': version.id,
  'effectiveFrom': version.effectiveFrom.toString(),
  'incomeMinor': version.income.minor,
  'groups': [
    for (final g in version.groups)
      {
        'id': g.id,
        'name': g.name,
        'shareBasisPoints': g.shareBasisPoints,
        'discretionary': g.discretionary,
      },
  ],
  'allocations': [
    for (final a in version.allocations)
      {
        'targetKind': a.targetKind.name,
        'targetId': a.targetId,
        'plannedMinor': a.planned.minor,
        'groupId': a.groupId,
        'rollover': a.rollover?.name,
      },
  ],
};

BudgetVersion budgetVersionFromJson(
  Map<String, Object?> json,
  Currency currency,
) => BudgetVersion(
  id: json['id'] as String,
  effectiveFrom: _requireDate(json['effectiveFrom']),
  income: Money(json['incomeMinor'] as int, currency),
  groups: [
    for (final g in _list(json['groups']))
      BudgetGroup(
        id: g['id'] as String,
        name: g['name'] as String,
        shareBasisPoints: g['shareBasisPoints'] as int,
        discretionary: g['discretionary'] as bool? ?? false,
      ),
  ],
  allocations: [
    for (final a in _list(json['allocations']))
      BudgetAllocation(
        targetKind: AllocationTargetKind.values.byName(
          a['targetKind'] as String,
        ),
        targetId: a['targetId'] as String,
        planned: Money(a['plannedMinor'] as int, currency),
        groupId: a['groupId'] as String?,
        rollover: a['rollover'] == null
            ? null
            : RolloverPolicy.values.byName(a['rollover'] as String),
      ),
  ],
);

/// A plan embeds its period schedule and every version; versions embed
/// their groups and allocations as values.
Map<String, Object?> budgetPlanToJson(BudgetPlan plan) => {
  'id': plan.id,
  'name': plan.name,
  'mode': plan.mode.name,
  'schedule': periodScheduleToJson(plan.schedule),
  'versions': [for (final v in plan.versions) budgetVersionToJson(v)],
};

BudgetPlan budgetPlanFromJson(Map<String, Object?> json, Currency currency) =>
    BudgetPlan(
      id: json['id'] as String,
      name: json['name'] as String,
      mode: BudgetMode.values.byName(json['mode'] as String),
      schedule: periodScheduleFromJson(_map(json['schedule'])),
      versions: [
        for (final v in _list(json['versions']))
          budgetVersionFromJson(v, currency),
      ],
    );

Map<String, Object?> budgetAdjustmentToJson(BudgetAdjustment a) => {
  'id': a.id,
  'planId': a.planId,
  'targetId': a.targetId,
  'periodStart': a.periodStart.toString(),
  'amountMinor': a.amount.minor,
  'approved': a.approved,
  'note': a.note,
};

BudgetAdjustment budgetAdjustmentFromJson(
  Map<String, Object?> json,
  Currency currency,
) => BudgetAdjustment(
  id: json['id'] as String,
  planId: json['planId'] as String,
  targetId: json['targetId'] as String,
  periodStart: _requireDate(json['periodStart']),
  amount: Money(json['amountMinor'] as int, currency),
  approved: json['approved'] as bool? ?? true,
  note: json['note'] as String?,
);

Map<String, Object?> goalToJson(Goal goal) => {
  'id': goal.id,
  'name': goal.name,
  'kind': goal.kind.name,
  'targetMinor': goal.target.minor,
  'targetDate': _date(goal.targetDate),
  'linkedAccountId': goal.linkedAccountId,
  'categoryId': goal.categoryId,
  'plannedContributionMinor': goal.plannedContribution?.minor,
  'contributionFrequency': goal.contributionFrequency?.name,
  'archived': goal.archived,
};

Goal goalFromJson(Map<String, Object?> json, Currency currency) => Goal(
  id: json['id'] as String,
  name: json['name'] as String,
  kind: GoalKind.values.byName(json['kind'] as String? ?? 'savings'),
  target: Money(json['targetMinor'] as int, currency),
  targetDate: _parseDate(json['targetDate']),
  linkedAccountId: json['linkedAccountId'] as String?,
  categoryId: json['categoryId'] as String?,
  plannedContribution: _money(json['plannedContributionMinor'], currency),
  contributionFrequency: json['contributionFrequency'] == null
      ? null
      : Frequency.values.byName(json['contributionFrequency'] as String),
  archived: json['archived'] as bool? ?? false,
);

Map<String, Object?> savingsAllocationToJson(SavingsAllocation a) => {
  'id': a.id,
  'goalId': a.goalId,
  'date': a.date.toString(),
  'amountMinor': a.amount.minor,
  'transferJournalId': a.transferJournalId,
  'note': a.note,
};

SavingsAllocation savingsAllocationFromJson(
  Map<String, Object?> json,
  Currency currency,
) => SavingsAllocation(
  id: json['id'] as String,
  goalId: json['goalId'] as String,
  date: _requireDate(json['date']),
  amount: Money(json['amountMinor'] as int, currency),
  transferJournalId: json['transferJournalId'] as String?,
  note: json['note'] as String?,
);

Map<String, Object?> reservationToJson(Reservation r) => {
  'id': r.id,
  'goalId': r.goalId,
  'accountId': r.accountId,
  'amountMinor': r.amount.minor,
  'confirmed': r.confirmed,
};

Reservation reservationFromJson(Map<String, Object?> json, Currency currency) =>
    Reservation(
      id: json['id'] as String,
      goalId: json['goalId'] as String,
      accountId: json['accountId'] as String,
      amount: Money(json['amountMinor'] as int, currency),
      confirmed: json['confirmed'] as bool? ?? true,
    );

Map<String, Object?> recurrenceToJson(Recurrence r) => {
  'frequency': r.frequency.name,
  'interval': r.interval,
  'start': r.start.toString(),
  'until': _date(r.until),
  'count': r.count,
  'monthEnd': r.monthEnd.name,
  'dayOfMonth': r.dayOfMonth,
};

Recurrence recurrenceFromJson(Map<String, Object?> json) => Recurrence(
  frequency: Frequency.values.byName(json['frequency'] as String),
  interval: json['interval'] as int? ?? 1,
  start: _requireDate(json['start']),
  until: _parseDate(json['until']),
  count: json['count'] as int?,
  monthEnd: MonthEndRule.values.byName(json['monthEnd'] as String? ?? 'clamp'),
  dayOfMonth: json['dayOfMonth'] as int?,
);

Map<String, Object?> reminderPreferenceToJson(ReminderPreference r) => {
  'enabled': r.enabled,
  'leadDays': r.leadDays,
  'minuteOfDay': r.minuteOfDay,
  'quietStartMinute': r.quietStartMinute,
  'quietEndMinute': r.quietEndMinute,
  'showDetails': r.showDetails,
};

ReminderPreference reminderPreferenceFromJson(Map<String, Object?> json) =>
    ReminderPreference(
      enabled: json['enabled'] as bool? ?? true,
      leadDays: json['leadDays'] as int? ?? 1,
      minuteOfDay: json['minuteOfDay'] as int? ?? 540,
      quietStartMinute: json['quietStartMinute'] as int?,
      quietEndMinute: json['quietEndMinute'] as int?,
      showDetails: json['showDetails'] as bool? ?? false,
    );

Map<String, Object?> recurringScheduleToJson(RecurringSchedule s) => {
  'id': s.id,
  'name': s.name,
  'kind': s.kind.name,
  'recurrence': recurrenceToJson(s.recurrence),
  'amountMinor': s.amount.minor,
  'isEstimate': s.isEstimate,
  'accountId': s.accountId,
  'counterAccountId': s.counterAccountId,
  'categoryId': s.categoryId,
  'payee': s.payee,
  'reminder': reminderPreferenceToJson(s.reminder),
  'confirmed': s.confirmed,
  'previousScheduleId': s.previousScheduleId,
};

RecurringSchedule recurringScheduleFromJson(
  Map<String, Object?> json,
  Currency currency,
) => RecurringSchedule(
  id: json['id'] as String,
  name: json['name'] as String,
  kind: ScheduleKind.values.byName(json['kind'] as String),
  recurrence: recurrenceFromJson(_map(json['recurrence'])),
  amount: Money(json['amountMinor'] as int, currency),
  isEstimate: json['isEstimate'] as bool? ?? false,
  accountId: json['accountId'] as String,
  counterAccountId: json['counterAccountId'] as String?,
  categoryId: json['categoryId'] as String?,
  payee: json['payee'] as String?,
  reminder: json['reminder'] == null
      ? const ReminderPreference()
      : reminderPreferenceFromJson(_map(json['reminder'])),
  confirmed: json['confirmed'] as bool? ?? true,
  previousScheduleId: json['previousScheduleId'] as String?,
);

Map<String, Object?> occurrenceOverrideToJson(OccurrenceOverride o) => {
  'id': o.id,
  'scheduleId': o.scheduleId,
  'originalDate': o.originalDate.toString(),
  'dueDate': _date(o.dueDate),
  'amountMinor': o.amount?.minor,
  'skipped': o.skipped,
};

OccurrenceOverride occurrenceOverrideFromJson(
  Map<String, Object?> json,
  Currency currency,
) => OccurrenceOverride(
  id: json['id'] as String,
  scheduleId: json['scheduleId'] as String,
  originalDate: _requireDate(json['originalDate']),
  dueDate: _parseDate(json['dueDate']),
  amount: _money(json['amountMinor'], currency),
  skipped: json['skipped'] as bool? ?? false,
);

Map<String, Object?> occurrencePaymentToJson(OccurrencePayment p) => {
  'id': p.id,
  'scheduleId': p.scheduleId,
  'occurrenceDate': p.occurrenceDate.toString(),
  'journalId': p.journalId,
  'amountMinor': p.amount.minor,
  'settles': p.settles,
};

OccurrencePayment occurrencePaymentFromJson(
  Map<String, Object?> json,
  Currency currency,
) => OccurrencePayment(
  id: json['id'] as String,
  scheduleId: json['scheduleId'] as String,
  occurrenceDate: _requireDate(json['occurrenceDate']),
  journalId: json['journalId'] as String,
  amount: Money(json['amountMinor'] as int, currency),
  settles: json['settles'] as bool? ?? false,
);

Map<String, Object?> insightStateToJson(InsightState s) => {
  'id': s.id,
  'insightKey': s.insightKey,
  'dismissed': s.dismissed,
  'snoozedUntil': _date(s.snoozedUntil),
};

InsightState insightStateFromJson(Map<String, Object?> json) => InsightState(
  id: json['id'] as String,
  insightKey: json['insightKey'] as String,
  dismissed: json['dismissed'] as bool? ?? false,
  snoozedUntil: _parseDate(json['snoozedUntil']),
);

Map<String, Object?> insightRuleSettingToJson(InsightRuleSetting s) => {
  'id': s.id,
  'rule': s.rule.name,
  'enabled': s.enabled,
  'thresholdMinor': s.threshold?.minor,
};

InsightRuleSetting insightRuleSettingFromJson(
  Map<String, Object?> json,
  Currency currency,
) => InsightRuleSetting(
  id: json['id'] as String,
  rule: InsightRule.values.byName(json['rule'] as String),
  enabled: json['enabled'] as bool? ?? true,
  threshold: _money(json['thresholdMinor'], currency),
);
