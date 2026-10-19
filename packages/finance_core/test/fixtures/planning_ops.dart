import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'ops.dart';

/// Fixture operations for budgeting, schedules and forecasts. Semantics are
/// documented in `spec/fixtures/README.md` under "Planning operations".
final Map<String, FixtureOp> planningOps = {
  'periods.generate': _periodsGenerate,
  'schedule.occurrences': _scheduleOccurrences,
  'budget.remaining': _budgetRemaining,
  'rollover.next': _rolloverNext,
  'allocation.template': _allocationTemplate,
  'monthly.equivalent': _monthlyEquivalent,
  'discretionary.estimate': _discretionaryEstimate,
  'forecast.daily': _forecastDaily,
};

typedef _Json = Map<String, dynamic>;

LocalDate _date(Object? text) => LocalDate.parse(text as String);
LocalDate? _optionalDate(Object? text) => text == null ? null : _date(text);
List<_Json> _list(Object? value) => (value as List? ?? const []).cast<_Json>();

Currency _currency(_Json input) => Currency(
  input['currency'] as String? ?? 'AUD',
  input['exponent'] as int? ?? 2,
);

MonthEndRule _monthEnd(Object? name) =>
    MonthEndRule.values.byName(name as String? ?? 'clamp');

void _periodsGenerate(_Json input, _Json expected) {
  final schedule = PeriodSchedule(
    cycle: PeriodCycle.values.byName(input['cycle'] as String),
    anchor: _date(input['anchor']),
    lengthDays: input['lengthDays'] as int?,
    timezone: input['timezone'] as String? ?? 'Australia/Sydney',
    monthEnd: _monthEnd(input['endOfMonth']),
  );
  expect([
    for (final p in schedule.generate(input['count'] as int))
      {'start': p.start.toString(), 'end': p.end.toString()},
  ], expected['periods']);
}

Recurrence _recurrence(_Json input) => Recurrence(
  frequency: Frequency.values.byName(input['frequency'] as String),
  interval: input['interval'] as int? ?? 1,
  start: _date(input['start']),
  until: _optionalDate(input['until']),
  count: input['count'] as int?,
  monthEnd: _monthEnd(input['endOfMonth']),
  dayOfMonth: input['dayOfMonth'] as int?,
);

void _scheduleOccurrences(_Json input, _Json expected) {
  Object result;
  try {
    result = [for (final d in _recurrence(input).dates()) d.toString()];
  } on StateError {
    result = 'UNBOUNDED';
  } on ArgumentError {
    result = 'INVALID';
  }
  expect(result, expected['dates'] ?? expected['error']);
}

void _budgetRemaining(_Json input, _Json expected) {
  final currency = _currency(input);
  Money money(String key) => Money.parse(input[key] as String, currency);
  final result = budgetRemaining(
    planned: money('planned'),
    openingRollover: money('rollover'),
    adjustments: money('adjustments'),
    postedNet: money('postedNet'),
    pending: money('pending'),
  );
  expect(result.remaining.toDecimalString(), expected['remaining']);
  expect(
    result.remainingAfterPending.toDecimalString(),
    expected['remainingAfterPending'],
  );
}

void _rolloverNext(_Json input, _Json expected) {
  final policy = RolloverPolicy.values.byName(input['policy'] as String);
  final remaining = Money.parse(input['remaining'] as String, _currency(input));
  expect(policy.nextOpening(remaining).toDecimalString(), expected['opening']);
}

void _allocationTemplate(_Json input, _Json expected) {
  final currency = _currency(input);
  final groups = (input['groups'] as List).cast<String>();
  final weights = (input['weights'] as List).cast<int>();
  final result = allocateTemplate(
    Money.parse(input['income'] as String, currency),
    [
      for (var i = 0; i < groups.length; i++)
        TemplateGroup(groups[i], weights[i]),
    ],
  );
  expect(
    result.amounts.map((k, v) => MapEntry(k, v.toDecimalString())),
    expected['amounts'],
  );
  expect(result.unassigned.toDecimalString(), expected['unassigned']);
}

void _monthlyEquivalent(_Json input, _Json expected) {
  final result = monthlyEquivalent(
    Money.parse(input['amount'] as String, _currency(input)),
    Frequency.values.byName(input['frequency'] as String),
    interval: input['interval'] as int? ?? 1,
  );
  expect(result.amount.toDecimalString(), expected['amount']);
  expect(result.annualFactor, expected['annualFactor']);
  expect(result.isEstimate, expected['isEstimate']);
}

/// Accounts, categories, entries, schedules, payments and reservations
/// shared by the forecast and discretionary operations.
class _Scenario {
  _Scenario(_Json input)
    : currency = _currency(input),
      today = _date(input['today']) {
    chart = Chart(
      currency: currency,
      accounts: [
        for (final a in _list(input['accounts']))
          Account(
            id: a['id'] as String,
            name: a['id'] as String,
            type: AccountType.values.byName(a['type'] as String),
            includeInForecast: a['includeInForecast'] as bool? ?? true,
          ),
      ],
      categories: [
        for (final c in _list(input['categories']))
          Category(
            id: c['id'] as String,
            name: c['id'] as String,
            kind: CategoryKind.values.byName(c['kind'] as String? ?? 'expense'),
          ),
      ],
    );
    final factory = JournalFactory(chart);
    final journals = <Journal>[
      for (final a in _list(input['accounts']))
        if (a['balance'] != null)
          factory.build(
            TransactionDraft(
              id: 'opening:${a['id']}',
              type: TransactionType.openingBalance,
              accountId: a['id'] as String,
              amount: money(a['balance']),
              effectiveDate: today,
            ),
          ),
      for (final e in _list(input['entries']))
        factory.build(
          TransactionDraft(
            id: e['id'] as String,
            type: TransactionType.values.byName(e['type'] as String),
            accountId: e['account'] as String,
            counterAccountId: e['to'] as String?,
            amount: money(e['amount']),
            effectiveDate: _date(e['date']),
            status: JournalStatus.values.byName(
              e['status'] as String? ?? 'posted',
            ),
            splits: e['category'] == null
                ? const []
                : [Split(e['category'] as String, money(e['amount']))],
          ),
        ),
    ];
    ledger = LedgerProjection(chart, journals);
    schedules = [
      for (final s in _list(input['schedules']))
        RecurringSchedule(
          id: s['id'] as String,
          name: s['id'] as String,
          kind: ScheduleKind.values.byName(s['kind'] as String),
          recurrence: _recurrence(s),
          amount: money(s['amount']),
          isEstimate: s['estimate'] as bool? ?? false,
          accountId: s['account'] as String,
          counterAccountId: s['to'] as String?,
          categoryId: s['category'] as String?,
          confirmed: s['confirmed'] as bool? ?? true,
        ),
    ];
    overrides = [
      for (final o in _list(input['overrides']))
        OccurrenceOverride(
          id: '${o['schedule']}@${o['originalDate']}',
          scheduleId: o['schedule'] as String,
          originalDate: _date(o['originalDate']),
          dueDate: _optionalDate(o['dueDate']),
          amount: o['amount'] == null ? null : money(o['amount']),
          skipped: o['skipped'] as bool? ?? false,
        ),
    ];
    payments = [
      for (final p in _list(input['payments']))
        OccurrencePayment(
          id: '${p['journal']}',
          scheduleId: p['schedule'] as String,
          occurrenceDate: _date(p['occurrence']),
          journalId: p['journal'] as String,
          amount: money(p['amount']),
          settles: p['settles'] as bool? ?? false,
        ),
    ];
    reservations = [
      for (final r in _list(input['reservations']))
        Reservation(
          id: r['id'] as String,
          goalId: r['goal'] as String? ?? r['id'] as String,
          accountId: r['account'] as String,
          amount: money(r['amount']),
          confirmed: r['confirmed'] as bool? ?? true,
        ),
    ];
    dataAsOf = {
      for (final a in _list(input['accounts']))
        if (a['dataAsOf'] != null) a['id'] as String: _date(a['dataAsOf']),
    };
  }

  final Currency currency;
  final LocalDate today;
  late final Chart chart;
  late final LedgerProjection ledger;
  late final List<RecurringSchedule> schedules;
  late final List<OccurrenceOverride> overrides;
  late final List<OccurrencePayment> payments;
  late final List<Reservation> reservations;
  late final Map<String, LocalDate> dataAsOf;

  Money money(Object? text) => Money.parse(text as String, currency);
  String? text(Money? value) => value?.toDecimalString();
}

void _discretionaryEstimate(_Json input, _Json expected) {
  final scenario = _Scenario(input);
  final budget = input['budget'] as _Json?;
  final plan = budget == null
      ? null
      : BudgetPlan(
          id: 'plan',
          name: 'plan',
          mode: BudgetMode.groups,
          schedule: PeriodSchedule(
            cycle: PeriodCycle.values.byName(budget['cycle'] as String),
            anchor: _date(budget['anchor']),
            lengthDays: budget['lengthDays'] as int?,
            timezone: 'Australia/Sydney',
          ),
          versions: [
            BudgetVersion(
              id: 'version',
              effectiveFrom: _date(budget['anchor']),
              income: scenario.money(budget['income']),
              groups: [
                for (final g in _list(budget['groups']))
                  BudgetGroup(
                    id: g['id'] as String,
                    name: g['id'] as String,
                    shareBasisPoints: g['share'] as int,
                    discretionary: g['discretionary'] as bool? ?? false,
                  ),
              ],
              allocations: [
                for (final a in _list(budget['allocations']))
                  BudgetAllocation.category(
                    a['category'] as String,
                    scenario.money(a['planned']),
                    groupId: a['group'] as String?,
                  ),
              ],
            ),
          ],
        );
  final result = estimateDiscretionary(
    plan: plan,
    ledger: scenario.ledger,
    today: scenario.today,
    horizonEnd: _date(input['horizonEnd']),
    schedules: scenario.schedules,
    overrides: scenario.overrides,
    payments: scenario.payments,
    reservations: scenario.reservations,
    minimumBuffer: input['buffer'] == null
        ? null
        : scenario.money(input['buffer']),
    accountDataAsOf: scenario.dataAsOf,
    staleAfterDays: input['staleAfterDays'] as int? ?? 3,
  );
  expect(scenario.text(result.budgetLimit), expected['budgetLimit']);
  expect(scenario.text(result.cashLimit), expected['cashLimit']);
  expect(scenario.text(result.estimate), expected['estimate']);
  expect(scenario.text(result.shortfall), expected['shortfall']);
  expect(result.complete, expected['complete']);
  if (expected.containsKey('missingInputs')) {
    expect(result.missingInputs, expected['missingInputs']);
  }
  if (expected.containsKey('lowestDate')) {
    expect(result.lowestBalanceDate.toString(), expected['lowestDate']);
  }
}

void _forecastDaily(_Json input, _Json expected) {
  final scenario = _Scenario(input);
  final changes = <ScenarioChange>[
    for (final c in _list(input['scenario']))
      switch (c['type'] as String) {
        'oneOff' => OneOffChange(
          id: c['id'] as String,
          date: _date(c['date']),
          accountId: c['account'] as String,
          amount: scenario.money(c['amount']),
        ),
        'scheduleAmount' => ScheduleAmountChange(
          id: c['id'] as String,
          scheduleId: c['schedule'] as String,
          amount: scenario.money(c['amount']),
        ),
        'removeSchedule' => RemoveScheduleChange(
          id: c['id'] as String,
          scheduleId: c['schedule'] as String,
        ),
        final other => throw ArgumentError('Unknown scenario change $other'),
      },
  ];
  final forecast = buildCashForecast(
    ledger: scenario.ledger,
    today: scenario.today,
    horizonDays: input['horizonDays'] as int? ?? 90,
    schedules: scenario.schedules,
    overrides: scenario.overrides,
    payments: scenario.payments,
    reservations: scenario.reservations,
    scenario: changes.isEmpty
        ? null
        : Scenario(id: 'scenario', name: 'scenario', changes: changes),
  );
  expect(forecast.days, hasLength(input['horizonDays'] as int? ?? 90));
  expect(scenario.text(forecast.openingBalance), expected['openingBalance']);
  expect(scenario.text(forecast.lowestBalance), expected['lowestBalance']);
  expect(forecast.lowestDate.toString(), expected['lowestDate']);
  (expected['days'] as Map<String, dynamic>? ?? {}).forEach((date, closing) {
    expect(
      scenario.text(forecast.day(_date(date))!.closing),
      closing,
      reason: 'closing $date',
    );
  });
  final totals = <String, Money>{
    for (final c in ForecastCertainty.values)
      c.name: Money.zero(scenario.currency),
  };
  for (final line in forecast.lines) {
    totals[line.certainty.name] = totals[line.certainty.name]! + line.amount;
  }
  (expected['certaintyTotals'] as Map<String, dynamic>? ?? {}).forEach((
    certainty,
    total,
  ) {
    expect(scenario.text(totals[certainty]), total, reason: certainty);
  });
}
