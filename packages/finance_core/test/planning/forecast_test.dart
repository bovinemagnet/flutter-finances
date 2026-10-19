import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
      Account(id: 'cash', name: 'Wallet', type: AccountType.cash),
      Account(
        id: 'goalSavings',
        name: 'Goal savings',
        type: AccountType.savings,
        includeInForecast: false,
      ),
      Account(id: 'card', name: 'Card', type: AccountType.creditCard),
      Account(id: 'house', name: 'House', type: AccountType.property),
    ],
    categories: const [
      Category(id: 'housing', name: 'Housing', kind: CategoryKind.expense),
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
      Category(id: 'streaming', name: 'Streaming', kind: CategoryKind.expense),
      Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
    ],
  );
  final factory = JournalFactory(chart);

  Journal opening(String id, String account, String amount, String date) =>
      factory.build(
        TransactionDraft(
          id: id,
          type: TransactionType.openingBalance,
          accountId: account,
          amount: m(amount),
          effectiveDate: d(date),
        ),
      );

  Journal expense(
    String id,
    String account,
    String category,
    String amount,
    String date, {
    JournalStatus status = JournalStatus.posted,
  }) => factory.build(
    TransactionDraft(
      id: id,
      type: TransactionType.expense,
      accountId: account,
      amount: m(amount),
      effectiveDate: d(date),
      status: status,
      splits: [Split(category, m(amount))],
    ),
  );

  RecurringSchedule bill(
    String id,
    String category,
    String amount,
    String date, {
    String account = 'bank',
  }) => RecurringSchedule(
    id: id,
    name: id,
    kind: ScheduleKind.expense,
    recurrence: Recurrence(frequency: Frequency.monthly, start: d(date)),
    amount: m(amount),
    accountId: account,
    categoryId: category,
  );

  group('cash forecast (PLAN 03)', () {
    test('runs 90 days over eligible liquid accounts only', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '1000.00', '2026-07-01'),
        opening('o2', 'cash', '50.00', '2026-07-01'),
        opening('o3', 'goalSavings', '800.00', '2026-07-01'),
        opening('o4', 'card', '300.00', '2026-07-01'),
        opening('o5', 'house', '500000.00', '2026-07-01'),
      ]);
      final forecast = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
      );
      expect(forecast.accountIds, {'bank', 'cash'});
      expect(forecast.days, hasLength(90));
      expect(forecast.start, d('2026-07-03'));
      expect(forecast.end, d('2026-09-30'));
      expect(forecast.openingBalance, m('1050.00'));
      expect(forecast.lowestBalance, m('1050.00'));
      expect(forecast.lowestDate, d('2026-07-03'));
    });

    test('tags actual, committed and hypothetical lines', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '1000.00', '2026-07-01'),
        expense(
          'p1',
          'bank',
          'dining',
          '40.00',
          '2026-07-02',
          status: JournalStatus.pending,
        ),
        expense('f1', 'bank', 'dining', '10.00', '2026-07-08'),
      ]);
      final forecast = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: [bill('rent', 'housing', '600.00', '2026-07-10')],
        scenario: Scenario(
          id: 's1',
          name: 'New phone',
          changes: [
            OneOffChange(
              id: 'c1',
              date: d('2026-07-12'),
              accountId: 'bank',
              amount: m('-300.00'),
              description: 'Phone',
            ),
          ],
        ),
      );
      final lines = forecast.lines;
      expect(
        lines.map((l) => (l.source, l.certainty, l.sourceId, l.date, l.amount)),
        [
          (
            ForecastSource.pending,
            ForecastCertainty.actual,
            'p1',
            d('2026-07-03'),
            m('-40.00'),
          ),
          (
            ForecastSource.posted,
            ForecastCertainty.actual,
            'f1',
            d('2026-07-08'),
            m('-10.00'),
          ),
          (
            ForecastSource.schedule,
            ForecastCertainty.committed,
            'rent@2026-07-10',
            d('2026-07-10'),
            m('-600.00'),
          ),
          (
            ForecastSource.scenario,
            ForecastCertainty.hypothetical,
            'c1',
            d('2026-07-12'),
            m('-300.00'),
          ),
        ],
      );
      expect(forecast.day(d('2026-07-12'))!.closing, m('50.00'));
      expect(forecast.lowestBalance, m('50.00'));
      expect(forecast.lowestDate, d('2026-07-12'));
      expect(forecast.includesHypothetical, isTrue);
    });

    test('a scenario changes the projection, never the ledger', () {
      final journals = [opening('o1', 'bank', '1000.00', '2026-07-01')];
      final ledger = LedgerProjection(chart, journals);
      final schedules = [bill('rent', 'housing', '600.00', '2026-07-10')];
      final base = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: schedules,
      );
      final scenario = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: schedules,
        scenario: Scenario(
          id: 's',
          name: 'Cheaper rent',
          changes: [
            ScheduleAmountChange(
              id: 'c',
              scheduleId: 'rent',
              amount: m('500.00'),
            ),
          ],
        ),
      );
      expect(base.lowestBalance, m('400.00'));
      expect(scenario.lowestBalance, m('500.00'));
      final rentLine = scenario.lines.singleWhere(
        (l) => l.sourceId == 'rent@2026-07-10',
      );
      expect(rentLine.certainty, ForecastCertainty.hypothetical);
      expect(ledger.journals, hasLength(1));
      expect(ledger.displayBalance('bank'), m('1000.00'));
      final removed = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: schedules,
        scenario: Scenario(
          id: 's',
          name: 'No rent',
          changes: [RemoveScheduleChange(id: 'c', scheduleId: 'rent')],
        ),
      );
      expect(removed.lowestBalance, m('1000.00'));
    });

    test(
      'a paid bill moves from forecast to actual with one cash effect (A13)',
      () {
        final rent = bill('rent', 'housing', '600.00', '2026-07-10');
        final before = buildCashForecast(
          ledger: LedgerProjection(chart, [
            opening('o1', 'bank', '1000.00', '2026-07-01'),
          ]),
          today: d('2026-07-03'),
          horizonDays: 14,
          schedules: [rent],
        );
        expect(before.day(d('2026-07-10'))!.closing, m('400.00'));

        final paidLedger = LedgerProjection(chart, [
          opening('o1', 'bank', '1000.00', '2026-07-01'),
          expense('j1', 'bank', 'housing', '600.00', '2026-07-03'),
        ]);
        final after = buildCashForecast(
          ledger: paidLedger,
          today: d('2026-07-03'),
          horizonDays: 14,
          schedules: [rent],
          payments: [
            OccurrencePayment(
              id: 'p',
              scheduleId: 'rent',
              occurrenceDate: d('2026-07-10'),
              journalId: 'j1',
              amount: m('600.00'),
            ),
          ],
        );
        expect(after.openingBalance, m('400.00'));
        expect(after.day(d('2026-07-10'))!.closing, m('400.00'));
        expect(
          after.lines.where((l) => l.source == ForecastSource.schedule),
          isEmpty,
        );
      },
    );

    test('a partial payment leaves the rest committed', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '1000.00', '2026-07-01'),
        expense('j1', 'bank', 'housing', '250.00', '2026-07-03'),
      ]);
      final forecast = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: [bill('rent', 'housing', '600.00', '2026-07-10')],
        payments: [
          OccurrencePayment(
            id: 'p',
            scheduleId: 'rent',
            occurrenceDate: d('2026-07-10'),
            journalId: 'j1',
            amount: m('250.00'),
          ),
        ],
      );
      expect(forecast.day(d('2026-07-10'))!.closing, m('400.00'));
    });

    test('a pending item that becomes posted is counted once', () {
      final pending = expense(
        'p1',
        'bank',
        'dining',
        '40.00',
        '2026-07-03',
        status: JournalStatus.pending,
      );
      final journals = [opening('o1', 'bank', '1000.00', '2026-07-01')];
      final asPending = buildCashForecast(
        ledger: LedgerProjection(chart, [...journals, pending]),
        today: d('2026-07-03'),
        horizonDays: 5,
      );
      final asPosted = buildCashForecast(
        ledger: LedgerProjection(chart, [
          ...journals,
          pending.copyWith(status: JournalStatus.posted),
        ]),
        today: d('2026-07-03'),
        horizonDays: 5,
      );
      expect(asPending.lowestBalance, m('960.00'));
      expect(asPosted.lowestBalance, m('960.00'));
    });

    test('income, transfers, unconfirmed income and reservations', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '1000.00', '2026-07-01'),
        opening('o2', 'goalSavings', '900.00', '2026-07-01'),
      ]);
      final forecast = buildCashForecast(
        ledger: ledger,
        today: d('2026-07-03'),
        horizonDays: 14,
        schedules: [
          RecurringSchedule(
            id: 'pay',
            name: 'Pay',
            kind: ScheduleKind.income,
            recurrence: Recurrence(
              frequency: Frequency.fortnightly,
              start: d('2026-07-09'),
            ),
            amount: m('2000.00'),
            accountId: 'bank',
            categoryId: 'salary',
          ),
          RecurringSchedule(
            id: 'bonus',
            name: 'Bonus',
            kind: ScheduleKind.income,
            recurrence: Recurrence(
              frequency: Frequency.annually,
              start: d('2026-07-05'),
            ),
            amount: m('5000.00'),
            accountId: 'bank',
            confirmed: false,
          ),
          RecurringSchedule(
            id: 'cardPayment',
            name: 'Card statement',
            kind: ScheduleKind.transfer,
            recurrence: Recurrence(
              frequency: Frequency.monthly,
              start: d('2026-07-06'),
            ),
            amount: m('300.00'),
            isEstimate: true,
            accountId: 'bank',
            counterAccountId: 'card',
          ),
          RecurringSchedule(
            id: 'toWallet',
            name: 'Cash out',
            kind: ScheduleKind.transfer,
            recurrence: Recurrence(
              frequency: Frequency.monthly,
              start: d('2026-07-07'),
            ),
            amount: m('100.00'),
            accountId: 'bank',
            counterAccountId: 'cash',
          ),
        ],
        reservations: [
          Reservation(
            id: 'r1',
            goalId: 'g',
            accountId: 'bank',
            amount: m('200.00'),
          ),
          Reservation(
            id: 'r2',
            goalId: 'g',
            accountId: 'goalSavings',
            amount: m('900.00'),
          ),
          Reservation(
            id: 'r3',
            goalId: 'g',
            accountId: 'bank',
            amount: m('50.00'),
            confirmed: false,
          ),
        ],
      );
      expect(forecast.day(d('2026-07-03'))!.closing, m('800.00'));
      expect(forecast.day(d('2026-07-05'))!.closing, m('800.00'));
      expect(forecast.day(d('2026-07-06'))!.closing, m('500.00'));
      expect(forecast.day(d('2026-07-07'))!.closing, m('500.00'));
      expect(forecast.day(d('2026-07-09'))!.closing, m('2500.00'));
      expect(forecast.lowestBalance, m('500.00'));
      expect(forecast.lowestDate, d('2026-07-06'));
      expect(
        forecast.lines
            .where((l) => l.sourceId == 'toWallet@2026-07-07')
            .map((l) => l.accountId),
        ['bank', 'cash'],
      );
    });
  });

  group('discretionary estimate (BUD 07)', () {
    final plan = BudgetPlan(
      id: 'plan',
      name: 'Household',
      mode: BudgetMode.groups,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2026-07-01'),
        timezone: 'Australia/Sydney',
      ),
      versions: [
        BudgetVersion(
          id: 'v1',
          effectiveFrom: d('2026-07-01'),
          income: m('5000.00'),
          groups: const [
            BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
            BudgetGroup(
              id: 'wants',
              name: 'Wants',
              shareBasisPoints: 3000,
              discretionary: true,
            ),
          ],
          allocations: [
            BudgetAllocation.category(
              'housing',
              m('2000.00'),
              groupId: 'needs',
            ),
            BudgetAllocation.category('dining', m('950.00'), groupId: 'wants'),
            BudgetAllocation.category(
              'streaming',
              m('150.00'),
              groupId: 'wants',
            ),
          ],
        ),
      ],
    );
    final schedules = [
      bill('rent', 'housing', '1050.00', '2026-07-10'),
      bill('stream', 'streaming', '150.00', '2026-07-12'),
    ];
    final fresh = {'bank': d('2026-07-03'), 'cash': d('2026-07-03')};

    List<Journal> workedExampleJournals() => [
      opening('o1', 'bank', '4250.00', '2026-07-01'),
      opening('o2', 'goalSavings', '800.00', '2026-07-01'),
      expense('j1', 'bank', 'dining', '250.00', '2026-07-02'),
      expense(
        'p1',
        'bank',
        'dining',
        '100.00',
        '2026-07-03',
        status: JournalStatus.pending,
      ),
    ];

    DiscretionaryEstimate estimate(
      List<Journal> journals, {
      Money? buffer,
      List<OccurrencePayment> payments = const [],
      Map<String, LocalDate> dataAsOf = const {},
      List<RecurringSchedule>? withSchedules,
    }) {
      final ledger = LedgerProjection(chart, journals);
      return estimateDiscretionary(
        plan: plan,
        ledger: ledger,
        today: d('2026-07-03'),
        horizonEnd: d('2026-07-16'),
        schedules: withSchedules ?? schedules,
        payments: payments,
        reservations: [
          Reservation(
            id: 'r1',
            goalId: 'g1',
            accountId: 'bank',
            amount: m('500.00'),
          ),
          Reservation(
            id: 'r2',
            goalId: 'g2',
            accountId: 'goalSavings',
            amount: m('800.00'),
          ),
        ],
        minimumBuffer: buffer,
        accountDataAsOf: dataAsOf,
      );
    }

    test(r'the PRD worked example gives $600', () {
      final result = estimate(
        workedExampleJournals(),
        buffer: m('500.00'),
        dataAsOf: fresh,
      );
      expect(result.cashLimit, m('1700.00'));
      expect(result.budgetLimit, m('600.00'));
      expect(result.estimate, m('600.00'));
      expect(result.shortfall, m('0.00'));
      expect(result.complete, isTrue);
      expect(result.missingInputs, isEmpty);
      expect(result.horizonStart, d('2026-07-03'));
      expect(result.horizonEnd, d('2026-07-16'));
      expect(result.sourceFreshness, d('2026-07-03'));
      expect(result.lowestBalanceDate, d('2026-07-12'));
    });

    test(
      'a negative limit is shown as a shortfall, not hidden behind zero',
      () {
        final result = estimate(
          workedExampleJournals(),
          buffer: m('2500.00'),
          dataAsOf: fresh,
        );
        expect(result.cashLimit, m('-300.00'));
        expect(result.estimate, m('0.00'));
        expect(result.shortfall, m('300.00'));
      },
    );

    test('incomplete inputs are labelled and listed', () {
      final result = estimate(
        workedExampleJournals(),
        dataAsOf: {'bank': d('2026-06-20')},
      );
      expect(result.complete, isFalse);
      expect(result.missingInputs, [
        'minimumBuffer',
        'staleAccountData:bank',
        'accountData:cash',
      ]);
      expect(result.cashLimit, m('2200.00'));
      expect(result.sourceFreshness, d('2026-06-20'));
    });

    test('a linked commitment that is posted is not subtracted twice', () {
      final journals = [
        ...workedExampleJournals(),
        expense('s1', 'bank', 'streaming', '150.00', '2026-07-03'),
      ];
      final result = estimate(
        journals,
        buffer: m('500.00'),
        dataAsOf: fresh,
        payments: [
          OccurrencePayment(
            id: 'pay',
            scheduleId: 'stream',
            occurrenceDate: d('2026-07-12'),
            journalId: 's1',
            amount: m('150.00'),
          ),
        ],
      );
      expect(result.cashLimit, m('1700.00'));
      expect(result.budgetLimit, m('600.00'));
      expect(result.estimate, m('600.00'));
    });

    test('pending card purchases reduce the budget limit but not cash', () {
      final result = estimate(
        [
          ...workedExampleJournals(),
          expense(
            'c1',
            'card',
            'dining',
            '80.00',
            '2026-07-03',
            status: JournalStatus.pending,
          ),
        ],
        buffer: m('500.00'),
        dataAsOf: fresh,
      );
      expect(result.budgetLimit, m('520.00'));
      expect(result.cashLimit, m('1700.00'));
    });

    test('income after the low point does not raise the cash limit', () {
      final result = estimate(
        workedExampleJournals(),
        buffer: m('500.00'),
        dataAsOf: fresh,
        withSchedules: [
          ...schedules,
          RecurringSchedule(
            id: 'pay',
            name: 'Pay',
            kind: ScheduleKind.income,
            recurrence: Recurrence(
              frequency: Frequency.fortnightly,
              start: d('2026-07-14'),
            ),
            amount: m('3000.00'),
            accountId: 'bank',
          ),
        ],
      );
      expect(result.cashLimit, m('1700.00'));
    });

    test('limit arithmetic', () {
      expect(combineLimits(m('5.00'), m('3.00')), (m('3.00'), m('0.00')));
      expect(combineLimits(m('-5.00'), m('3.00')), (m('0.00'), m('5.00')));
      expect(combineLimits(m('-5.00'), m('-8.00')), (m('0.00'), m('8.00')));
      expect(combineLimits(null, m('3.00')), (m('3.00'), m('0.00')));
    });
  });
}
