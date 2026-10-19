import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  final fiftyThirtyTwenty = [
    const TemplateGroup('needs', 5000),
    const TemplateGroup('wants', 3000),
    const TemplateGroup('savings', 2000),
  ];

  group('template allocation', () {
    test('50/30/20 allocates take-home income exactly', () {
      final result = allocateTemplate(m('3123.45'), fiftyThirtyTwenty);
      expect(result.amounts, {
        'needs': m('1561.73'),
        'wants': m('937.03'),
        'savings': m('624.69'),
      });
      expect(result.unassigned, m('0.00'));
    });

    test('percentages under 100% leave unassigned money', () {
      final result = allocateTemplate(m('1000.00'), const [
        TemplateGroup('needs', 5000),
        TemplateGroup('wants', 3000),
        TemplateGroup('savings', 1500),
      ]);
      expect(result.amounts['savings'], m('150.00'));
      expect(result.unassigned, m('50.00'));
    });

    test(
      'percentages over 100% show over-allocation as negative unassigned',
      () {
        final result = allocateTemplate(m('1000.00'), const [
          TemplateGroup('needs', 5000),
          TemplateGroup('wants', 3000),
          TemplateGroup('savings', 3000),
        ]);
        expect(result.amounts['savings'], m('300.00'));
        expect(result.unassigned, m('-100.00'));
      },
    );

    test('a group amount splits across categories by weight', () {
      expect(allocateWithinGroup(m('500.00'), {'rent': 2, 'power': 1}), {
        'rent': m('333.33'),
        'power': m('166.67'),
      });
    });

    test('a version can be built from a template', () {
      final version = BudgetVersion.fromTemplate(
        id: 'v1',
        effectiveFrom: d('2026-07-01'),
        income: m('1000.00'),
        groups: [
          const BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
          const BudgetGroup(
            id: 'wants',
            name: 'Wants',
            shareBasisPoints: 3000,
            discretionary: true,
          ),
          const BudgetGroup(
            id: 'savings',
            name: 'Savings',
            shareBasisPoints: 2000,
          ),
        ],
        categoryWeights: {
          'needs': {'rent': 4, 'groceries': 1},
          'wants': {'dining': 1},
        },
      );
      expect(version.allocationFor('rent')!.planned, m('400.00'));
      expect(version.allocationFor('groceries')!.planned, m('100.00'));
      expect(version.allocationFor('dining')!.groupId, 'wants');
      final summary = version.summary();
      expect(summary.allocated, m('800.00'));
      expect(summary.unassigned, m('200.00'));
      expect(summary.overAllocated, m('0.00'));
      final savings = summary.groups.singleWhere((g) => g.groupId == 'savings');
      expect(savings.target, m('200.00'));
      expect(savings.unassigned, m('200.00'));
    });
  });

  group('allocation summary', () {
    test('shows over-allocation of income and of a group explicitly', () {
      final version = BudgetVersion(
        id: 'v1',
        effectiveFrom: d('2026-07-01'),
        income: m('1000.00'),
        groups: const [
          BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
          BudgetGroup(id: 'wants', name: 'Wants', shareBasisPoints: 5000),
        ],
        allocations: [
          BudgetAllocation.category('rent', m('520.00'), groupId: 'needs'),
          BudgetAllocation.category('dining', m('530.00'), groupId: 'wants'),
        ],
      );
      final summary = version.summary();
      expect(summary.overAllocated, m('50.00'));
      expect(summary.unassigned, m('0.00'));
      final needs = summary.groups.firstWhere((g) => g.groupId == 'needs');
      expect(needs.overAllocated, m('20.00'));
      expect(needs.unassigned, m('0.00'));
    });

    test('category-only mode uses the same model without groups', () {
      final version = BudgetVersion(
        id: 'v1',
        effectiveFrom: d('2026-07-01'),
        income: m('1000.00'),
        allocations: [BudgetAllocation.category('rent', m('600.00'))],
      );
      final plan = BudgetPlan(
        id: 'p',
        name: 'Simple',
        mode: BudgetMode.categoryOnly,
        schedule: PeriodSchedule(
          cycle: PeriodCycle.month,
          anchor: d('2026-07-01'),
          timezone: 'Australia/Sydney',
        ),
        versions: [version],
      );
      expect(plan.versions.single.summary().unassigned, m('400.00'));
      expect(plan.versions.single.summary().groups, isEmpty);
    });

    test(
      'category-only plans reject groups and allocations need known groups',
      () {
        expect(
          () => BudgetVersion(
            id: 'v1',
            effectiveFrom: d('2026-07-01'),
            income: m('1.00'),
            allocations: [
              BudgetAllocation.category('rent', m('1.00'), groupId: 'nope'),
            ],
          ),
          throwsArgumentError,
        );
        expect(
          () => BudgetPlan(
            id: 'p',
            name: 'Simple',
            mode: BudgetMode.categoryOnly,
            schedule: PeriodSchedule(
              cycle: PeriodCycle.month,
              anchor: d('2026-07-01'),
              timezone: 'UTC',
            ),
            versions: [
              BudgetVersion(
                id: 'v1',
                effectiveFrom: d('2026-07-01'),
                income: m('1.00'),
                groups: const [
                  BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 1),
                ],
              ),
            ],
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('remaining and rollover arithmetic', () {
    test('remaining = planned + rollover + adjustments - posted net', () {
      final result = budgetRemaining(
        planned: m('500.00'),
        openingRollover: m('20.00'),
        adjustments: m('30.00'),
        postedNet: m('400.00'),
        pending: m('70.00'),
      );
      expect(result.remaining, m('150.00'));
      expect(result.remainingAfterPending, m('80.00'));
    });

    test('rollover policies', () {
      expect(RolloverPolicy.none.nextOpening(m('10.00')), m('0.00'));
      expect(RolloverPolicy.positiveOnly.nextOpening(m('10.00')), m('10.00'));
      expect(RolloverPolicy.positiveOnly.nextOpening(m('-10.00')), m('0.00'));
      expect(RolloverPolicy.signed.nextOpening(m('-10.00')), m('-10.00'));
    });
  });

  group('versions', () {
    final schedule = PeriodSchedule(
      cycle: PeriodCycle.month,
      anchor: d('2026-07-01'),
      timezone: 'Australia/Sydney',
    );
    BudgetVersion version(String id, String from, String rent) => BudgetVersion(
      id: id,
      effectiveFrom: d(from),
      income: m('1000.00'),
      allocations: [BudgetAllocation.category('rent', m(rent))],
    );
    final plan = BudgetPlan(
      id: 'p',
      name: 'Household',
      mode: BudgetMode.categoryOnly,
      schedule: schedule,
      versions: [version('v1', '2026-07-01', '500.00')],
    );

    test('a future change keeps earlier periods on the earlier version', () {
      final changed = plan.withVersion(
        version('v2', '2026-09-01', '550.00'),
        today: d('2026-08-15'),
      );
      expect(changed.versions, hasLength(2));
      expect(
        changed.versionFor(schedule.periodContaining(d('2026-08-10')))!.id,
        'v1',
      );
      expect(
        changed.versionFor(schedule.periodContaining(d('2026-10-10')))!.id,
        'v2',
      );
      expect(plan.versions, hasLength(1), reason: 'plans are immutable');
    });

    test('past periods cannot be rewritten', () {
      expect(
        () => plan.withVersion(
          version('v2', '2026-07-01', '550.00'),
          today: d('2026-08-15'),
        ),
        throwsStateError,
      );
    });

    test('the current period can be replaced, and starts must align', () {
      final changed = plan
          .withVersion(
            version('v2', '2026-08-01', '550.00'),
            today: d('2026-08-15'),
          )
          .withVersion(
            version('v3', '2026-08-01', '560.00'),
            today: d('2026-08-15'),
          );
      expect(changed.versions.map((v) => v.id), ['v1', 'v3']);
      expect(
        () => plan.withVersion(
          version('v4', '2026-09-02', '1.00'),
          today: d('2026-08-15'),
        ),
        throwsArgumentError,
      );
    });

    test('periods before the first version have no plan', () {
      expect(
        plan.versionFor(schedule.periodContaining(d('2026-06-10'))),
        isNull,
      );
    });
  });

  group('evaluation against the ledger', () {
    late Chart chart;
    late JournalFactory factory;

    setUp(() {
      chart = Chart(
        currency: aud,
        accounts: const [
          Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
          Account(id: 'card', name: 'Card', type: AccountType.creditCard),
          Account(id: 'loan', name: 'Car loan', type: AccountType.loan),
          Account(id: 'savings', name: 'Savings', type: AccountType.savings),
        ],
        categories: const [
          Category(
            id: 'groceries',
            name: 'Groceries',
            kind: CategoryKind.expense,
          ),
          Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
          Category(id: 'fuel', name: 'Fuel', kind: CategoryKind.expense),
          Category(
            id: 'interest',
            name: 'Interest',
            kind: CategoryKind.expense,
          ),
          Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
        ],
      );
      factory = JournalFactory(chart);
    });

    Journal expense(
      String id,
      String category,
      String amount,
      String date, {
      String account = 'bank',
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

    Journal transfer(
      String id,
      String from,
      String to,
      String amount,
      String date,
    ) => factory.build(
      TransactionDraft(
        id: id,
        type: TransactionType.transfer,
        accountId: from,
        counterAccountId: to,
        amount: m(amount),
        effectiveDate: d(date),
      ),
    );

    BudgetPlan planWith(
      List<BudgetAllocation> allocations, {
      RolloverPolicy rollover = RolloverPolicy.positiveOnly,
    }) => BudgetPlan(
      id: 'p',
      name: 'Household',
      mode: BudgetMode.groups,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2026-07-01'),
        timezone: 'Australia/Sydney',
        rollover: rollover,
      ),
      versions: [
        BudgetVersion(
          id: 'v1',
          effectiveFrom: d('2026-07-01'),
          income: m('4000.00'),
          groups: const [
            BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
            BudgetGroup(
              id: 'wants',
              name: 'Wants',
              shareBasisPoints: 3000,
              discretionary: true,
            ),
            BudgetGroup(id: 'savings', name: 'Savings', shareBasisPoints: 2000),
          ],
          allocations: allocations,
        ),
      ],
    );

    test('remaining, pending, adjustments and positive rollover', () {
      final ledger = LedgerProjection(chart, [
        expense('j1', 'groceries', '120.00', '2026-07-03'),
        expense(
          'j2',
          'groceries',
          '30.00',
          '2026-07-30',
          status: JournalStatus.pending,
        ),
        expense('j3', 'groceries', '50.00', '2026-08-02'),
        expense('j4', 'fuel', '45.00', '2026-07-04'),
      ]);
      final plan = planWith([
        BudgetAllocation.category('groceries', m('200.00'), groupId: 'needs'),
      ]);
      final evaluator = BudgetEvaluator(
        plan: plan,
        ledger: ledger,
        adjustments: [
          BudgetAdjustment(
            id: 'a1',
            planId: 'p',
            targetId: 'groceries',
            periodStart: d('2026-08-01'),
            amount: m('25.00'),
          ),
          BudgetAdjustment(
            id: 'a2',
            planId: 'p',
            targetId: 'groceries',
            periodStart: d('2026-08-01'),
            amount: m('999.00'),
            approved: false,
          ),
        ],
      );
      final july = evaluator.evaluateAt(d('2026-07-15'));
      final groceries = july.line('groceries')!;
      expect(groceries.postedNet, m('120.00'));
      expect(groceries.pending, m('30.00'));
      expect(groceries.remaining, m('80.00'));
      expect(groceries.remainingAfterPending, m('50.00'));
      expect(groceries.journalIds, ['j1']);
      expect(groceries.pendingJournalIds, ['j2']);
      expect(july.unbudgeted.single.targetId, 'fuel');
      expect(july.unbudgeted.single.postedNet, m('45.00'));

      final august = evaluator.evaluateAt(d('2026-08-15')).line('groceries')!;
      expect(august.openingRollover, m('80.00'));
      expect(august.adjustments, m('25.00'));
      expect(august.remaining, m('255.00'));
    });

    test('signed rollover carries overspending', () {
      final ledger = LedgerProjection(chart, [
        expense('j1', 'dining', '250.00', '2026-07-03'),
      ]);
      final plan = planWith([
        BudgetAllocation.category('dining', m('200.00'), groupId: 'wants'),
      ], rollover: RolloverPolicy.signed);
      final evaluator = BudgetEvaluator(plan: plan, ledger: ledger);
      expect(
        evaluator.evaluateAt(d('2026-08-01')).line('dining')!.openingRollover,
        m('-50.00'),
      );
      expect(
        evaluator.evaluateAt(d('2026-09-01')).line('dining')!.openingRollover,
        m('150.00'),
      );
    });

    test('an allocation can override the plan rollover policy', () {
      final ledger = LedgerProjection(chart, const []);
      final plan = planWith([
        BudgetAllocation.category(
          'dining',
          m('200.00'),
          groupId: 'wants',
          rollover: RolloverPolicy.none,
        ),
      ]);
      expect(
        BudgetEvaluator(
          plan: plan,
          ledger: ledger,
        ).evaluateAt(d('2026-08-01')).line('dining')!.openingRollover,
        m('0.00'),
      );
    });

    test(
      'savings allocations count toward the plan without an expense (A02)',
      () {
        final ledger = LedgerProjection(chart, [
          transfer('t1', 'bank', 'savings', '300.00', '2026-07-05'),
        ]);
        final plan = planWith([
          BudgetAllocation.goal('holiday', m('400.00'), groupId: 'savings'),
        ]);
        final evaluator = BudgetEvaluator(
          plan: plan,
          ledger: ledger,
          savingsAllocations: [
            SavingsAllocation(
              id: 's1',
              goalId: 'holiday',
              date: d('2026-07-05'),
              amount: m('300.00'),
              transferJournalId: 't1',
            ),
          ],
        );
        final july = evaluator.evaluateAt(d('2026-07-10'));
        expect(july.line('holiday')!.postedNet, m('300.00'));
        expect(july.line('holiday')!.journalIds, ['t1']);
        expect(ledger.expenses(d('2026-07-01'), d('2026-07-31')), m('0.00'));
        expect(july.group('savings')!.actual, m('300.00'));
      },
    );

    test('loan principal counts as debt reduction; interest stays an expense (BUD 06)', () {
      final ledger = LedgerProjection(chart, [
        transfer('t1', 'bank', 'loan', '500.00', '2026-07-05'),
        expense('j1', 'interest', '40.00', '2026-07-05', account: 'loan'),
        expense('j2', 'groceries', '120.00', '2026-07-06', account: 'card'),
        transfer('t2', 'bank', 'card', '120.00', '2026-07-20'),
      ]);
      final plan = planWith([
        BudgetAllocation.loanPrincipal('loan', m('500.00'), groupId: 'savings'),
        BudgetAllocation.category('interest', m('40.00'), groupId: 'needs'),
        BudgetAllocation.category('groceries', m('200.00'), groupId: 'needs'),
      ]);
      final july = BudgetEvaluator(
        plan: plan,
        ledger: ledger,
      ).evaluateAt(d('2026-07-10'));
      expect(july.line('loan')!.postedNet, m('500.00'));
      expect(july.line('loan')!.journalIds, ['t1']);
      expect(july.line('interest')!.postedNet, m('40.00'));
      expect(july.group('needs')!.actual, m('160.00'));
      expect(july.group('savings')!.actual, m('500.00'));
      expect(
        july.groups.fold(m('0.00'), (sum, g) => sum + g.actual),
        m('660.00'),
        reason: 'the card repayment is not counted again',
      );
    });

    test('a credit card cannot be a debt-reduction target', () {
      final plan = planWith([
        BudgetAllocation.loanPrincipal('card', m('100.00'), groupId: 'savings'),
      ]);
      expect(
        () => BudgetEvaluator(
          plan: plan,
          ledger: LedgerProjection(chart, const []),
        ).evaluateAt(d('2026-07-01')),
        throwsArgumentError,
      );
    });

    test('the activity index agrees with LedgerProjection.categoryNet', () {
      final journals = [
        expense('j1', 'groceries', '120.00', '2026-07-03'),
        expense(
          'j2',
          'groceries',
          '30.00',
          '2026-07-31',
          status: JournalStatus.pending,
        ),
        expense('j3', 'dining', '50.00', '2026-08-01'),
      ];
      final ledger = LedgerProjection(chart, journals);
      final index = CategoryActivityIndex.fromLedger(ledger);
      for (final category in ['groceries', 'dining']) {
        for (final pending in [false, true]) {
          expect(
            index.net(
              category,
              d('2026-07-01'),
              d('2026-07-31'),
              pending: pending,
            ),
            ledger.categoryNet(
              category,
              d('2026-07-01'),
              d('2026-07-31'),
              pending: pending,
            ),
          );
        }
      }
    });
  });
}
