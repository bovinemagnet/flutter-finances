import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  /// Encodes through a JSON string so only JSON types survive.
  Map<String, Object?> viaText(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  void roundTrips<T>(
    T value,
    Map<String, Object?> Function(T) encode,
    T Function(Map<String, Object?>) decode,
  ) {
    final json = encode(value);
    expect(json['id'], isA<String>());
    expect(encode(decode(viaText(json))), json);
  }

  test('budget plans with versions, groups and allocations', () {
    final plan = BudgetPlan(
      id: 'plan',
      name: 'Household',
      mode: BudgetMode.groups,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.custom,
        anchor: d('2026-07-02'),
        lengthDays: 10,
        timezone: 'Australia/Sydney',
        rollover: RolloverPolicy.signed,
      ),
      versions: [
        BudgetVersion(
          id: 'v1',
          effectiveFrom: d('2026-07-02'),
          income: m('4000.00'),
          groups: const [
            BudgetGroup(
              id: 'wants',
              name: 'Wants',
              shareBasisPoints: 3000,
              discretionary: true,
            ),
          ],
          allocations: [
            BudgetAllocation.category(
              'dining',
              m('300.00'),
              groupId: 'wants',
              rollover: RolloverPolicy.none,
            ),
            BudgetAllocation.goal('holiday', m('100.00')),
            BudgetAllocation.loanPrincipal('loan', m('200.00')),
          ],
        ),
      ],
    );
    final json = budgetPlanToJson(plan);
    expect((json['schedule'] as Map)['lengthDays'], 10);
    final version = (json['versions'] as List).first as Map;
    expect(version['incomeMinor'], 400000);
    expect((version['allocations'] as List).first, {
      'targetKind': 'category',
      'targetId': 'dining',
      'plannedMinor': 30000,
      'groupId': 'wants',
      'rollover': 'none',
    });
    roundTrips(plan, budgetPlanToJson, (j) => budgetPlanFromJson(j, aud));
  });

  test('monthly schedules keep their end-of-month rule', () {
    final plan = BudgetPlan(
      id: 'plan',
      name: 'Monthly',
      mode: BudgetMode.categoryOnly,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2026-04-30'),
        timezone: 'UTC',
        monthEnd: MonthEndRule.lastDay,
      ),
      versions: const [],
    );
    final back = budgetPlanFromJson(viaText(budgetPlanToJson(plan)), aud);
    expect(back.schedule.periodAt(1).start, d('2026-05-31'));
  });

  test('adjustments', () {
    roundTrips(
      BudgetAdjustment(
        id: 'a',
        planId: 'plan',
        targetId: 'dining',
        periodStart: d('2026-07-01'),
        amount: m('-25.00'),
        approved: false,
        note: 'Birthday',
      ),
      budgetAdjustmentToJson,
      (j) => budgetAdjustmentFromJson(j, aud),
    );
  });

  test('goals, savings allocations and reservations', () {
    roundTrips(
      Goal(
        id: 'g',
        name: 'Insurance',
        kind: GoalKind.sinkingFund,
        target: m('900.00'),
        targetDate: d('2027-03-01'),
        linkedAccountId: 'savings',
        categoryId: 'insurance',
        plannedContribution: m('75.00'),
        contributionFrequency: Frequency.monthly,
      ),
      goalToJson,
      (j) => goalFromJson(j, aud),
    );
    roundTrips(
      Goal(id: 'g2', name: 'Plain', target: m('1.00')),
      goalToJson,
      (j) => goalFromJson(j, aud),
    );
    roundTrips(
      SavingsAllocation(
        id: 's',
        goalId: 'g',
        date: d('2026-07-05'),
        amount: m('75.00'),
        transferJournalId: 't1',
      ),
      savingsAllocationToJson,
      (j) => savingsAllocationFromJson(j, aud),
    );
    roundTrips(
      Reservation(
        id: 'r',
        goalId: 'g',
        accountId: 'savings',
        amount: m('500.00'),
        confirmed: false,
      ),
      reservationToJson,
      (j) => reservationFromJson(j, aud),
    );
  });

  test('recurring schedules with recurrence and reminders', () {
    final schedule = RecurringSchedule(
      id: 'card',
      name: 'Card statement',
      kind: ScheduleKind.transfer,
      recurrence: Recurrence(
        frequency: Frequency.monthly,
        start: d('2027-02-28'),
        dayOfMonth: 31,
        until: d('2027-12-31'),
        count: 10,
      ),
      amount: m('300.00'),
      isEstimate: true,
      accountId: 'bank',
      counterAccountId: 'cardAccount',
      payee: 'Bank',
      reminder: const ReminderPreference(
        leadDays: 3,
        minuteOfDay: 600,
        quietStartMinute: 1320,
        quietEndMinute: 420,
        showDetails: true,
      ),
      confirmed: false,
      previousScheduleId: 'old',
    );
    final json = recurringScheduleToJson(schedule);
    expect((json['recurrence'] as Map)['dayOfMonth'], 31);
    expect(json['amountMinor'], 30000);
    roundTrips(
      schedule,
      recurringScheduleToJson,
      (j) => recurringScheduleFromJson(j, aud),
    );
  });

  test('occurrence overrides and payment links', () {
    roundTrips(
      OccurrenceOverride(
        id: 'o',
        scheduleId: 'rent',
        originalDate: d('2027-02-28'),
        dueDate: d('2027-03-01'),
        amount: m('2100.00'),
        skipped: false,
      ),
      occurrenceOverrideToJson,
      (j) => occurrenceOverrideFromJson(j, aud),
    );
    roundTrips(
      OccurrencePayment(
        id: 'p',
        scheduleId: 'rent',
        occurrenceDate: d('2027-02-28'),
        journalId: 'j1',
        amount: m('1950.00'),
        settles: true,
      ),
      occurrencePaymentToJson,
      (j) => occurrencePaymentFromJson(j, aud),
    );
  });

  test('insight state and rule settings', () {
    roundTrips(
      InsightState(
        id: 's',
        insightKey: 'lowCash:2026-07-20',
        snoozedUntil: d('2026-07-08'),
      ),
      insightStateToJson,
      insightStateFromJson,
    );
    roundTrips(
      InsightRuleSetting(
        id: 'r',
        rule: InsightRule.missingReceipt,
        threshold: m('100.00'),
      ),
      insightRuleSettingToJson,
      (j) => insightRuleSettingFromJson(j, aud),
    );
  });
}
