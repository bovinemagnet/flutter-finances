import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);
  final first = d('2026-11-15');

  group('debt payoff', () {
    test('charges monthly interest before each payment', () {
      final plan = simulateDebtPayoff(
        debts: [
          PayoffDebt(
            id: 'a',
            name: 'Card',
            balance: m('1000.00'),
            annualRateBasisPoints: 1200,
            minimumPayment: m('100.00'),
          ),
        ],
        strategy: PayoffStrategy.avalanche,
        firstPaymentDate: first,
      );
      final month1 = plan.months.first.lines.single;
      expect(month1.opening, m('1000.00'));
      expect(month1.interest, m('10.00'));
      expect(month1.payment, m('100.00'));
      expect(month1.closing, m('910.00'));
      // 819.10 × 1% = 8.191, rounded half away from zero.
      expect(plan.months[2].lines.single.interest, m('8.19'));
      expect(plan.months[1].date, d('2026-12-15'));
      expect(plan.completed, isTrue);
      expect(plan.months, hasLength(11));
      expect(plan.totalInterest, m('58.98'));
      expect(plan.totalPaid, m('1058.98'));
      expect(plan.payoffDates['a'], d('2027-09-15'));
      expect(plan.debtFreeDate, d('2027-09-15'));
      expect(plan.months.last.lines.single.closing, m('0.00'));
    });

    final debts = [
      PayoffDebt(
        id: 'a',
        name: 'Big card',
        balance: m('3000.00'),
        annualRateBasisPoints: 2200,
        minimumPayment: m('90.00'),
      ),
      PayoffDebt(
        id: 'b',
        name: 'Small card',
        balance: m('800.00'),
        annualRateBasisPoints: 1500,
        minimumPayment: m('30.00'),
      ),
    ];

    test('compares avalanche, snowball and minimum-only schedules', () {
      final comparison = compareDebtPayoffs(
        debts: debts,
        firstPaymentDate: first,
        extraMonthly: m('100.00'),
      );
      expect(comparison.avalanche.order, ['a', 'b']);
      expect(comparison.snowball.order, ['b', 'a']);
      expect(comparison.avalanche.totalInterest, m('724.18'));
      expect(comparison.snowball.totalInterest, m('786.53'));
      expect(comparison.minimumOnly.totalInterest, m('1857.99'));
      expect(comparison.avalanche.payoffDates, {
        'a': d('2028-05-15'),
        'b': d('2028-07-15'),
      });
      expect(comparison.snowball.payoffDates, {
        'a': d('2028-07-15'),
        'b': d('2027-05-15'),
      });
      expect(comparison.minimumOnly.debtFreeDate, d('2031-02-15'));
      expect(comparison.plan(PayoffStrategy.snowball).totalPaid, m('4586.53'));

      for (final plan in [
        comparison.avalanche,
        comparison.snowball,
        comparison.minimumOnly,
      ]) {
        // Every dollar paid is either the starting balance or interest.
        expect(plan.totalPaid, m('3800.00') + plan.totalInterest);
        for (final month in plan.months) {
          for (final line in month.lines) {
            expect(line.closing, line.opening + line.interest - line.payment);
          }
        }
      }
      // The freed minimum rolls over: the monthly outlay stays constant
      // until the final month.
      final outlays = [
        for (final month in comparison.avalanche.months) month.totalPayment,
      ];
      expect(outlays.take(outlays.length - 1), everyElement(m('220.00')));
    });

    test('reports a debt that minimum payments never repay', () {
      final plan = simulateDebtPayoff(
        debts: [
          PayoffDebt(
            id: 'x',
            name: 'Loan',
            balance: m('1000.00'),
            annualRateBasisPoints: 2400,
            minimumPayment: m('20.00'),
          ),
        ],
        strategy: PayoffStrategy.minimumOnly,
        firstPaymentDate: first,
        maxMonths: 24,
      );
      expect(plan.completed, isFalse);
      expect(plan.months, hasLength(24));
      expect(plan.payoffDates['x'], isNull);
      expect(plan.debtFreeDate, isNull);
    });

    test('rejects invalid inputs', () {
      expect(
        () => PayoffDebt(
          id: 'x',
          name: 'x',
          balance: m('1.00'),
          annualRateBasisPoints: -1,
          minimumPayment: m('1.00'),
        ),
        throwsArgumentError,
      );
      expect(
        () => PayoffDebt(
          id: 'x',
          name: 'x',
          balance: m('1.00'),
          annualRateBasisPoints: 100,
          minimumPayment: m('0.00'),
        ),
        throwsArgumentError,
      );
      expect(
        () => simulateDebtPayoff(
          debts: debts,
          strategy: PayoffStrategy.avalanche,
          firstPaymentDate: first,
          extraMonthly: m('-1.00'),
        ),
        throwsArgumentError,
      );
    });

    test('builds debts from ledger balances and saved terms', () {
      final chart = Chart(
        currency: aud,
        accounts: const [
          Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
          Account(id: 'loan', name: 'Car loan', type: AccountType.loan),
        ],
        categories: const [],
      );
      final factory = JournalFactory(chart);
      final ledger = LedgerProjection(chart, [
        factory.build(
          TransactionDraft(
            id: 'o',
            type: TransactionType.openingBalance,
            accountId: 'card',
            amount: m('1500.00'),
            effectiveDate: d('2026-10-01'),
          ),
        ),
      ]);
      final terms = [
        DebtTerms(
          id: 't1',
          accountId: 'card',
          annualRateBasisPoints: 1999,
          minimumPayment: m('45.00'),
        ),
        DebtTerms(
          id: 't2',
          accountId: 'loan',
          annualRateBasisPoints: 700,
          minimumPayment: m('300.00'),
        ),
      ];
      final payoff = payoffDebtsFromLedger(ledger, terms);
      expect(
        [for (final p in payoff) (p.id, p.name, p.balance)],
        [('card', 'Visa', m('1500.00')), ('loan', 'Car loan', m('0.00'))],
      );
      final json = debtTermsToJson(terms.first);
      expect(json, {
        'id': 't1',
        'accountId': 'card',
        'annualRateBasisPoints': 1999,
        'minimumPaymentMinor': 4500,
      });
      final back = debtTermsFromJson(json, aud);
      expect(back.minimumPayment, m('45.00'));
      expect(back.annualRateBasisPoints, 1999);
    });
  });

  group('zero-based budgets', () {
    final chart = Chart(
      currency: aud,
      accounts: const [
        Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
        Account(id: 'loan', name: 'Loan', type: AccountType.loan),
      ],
      categories: const [
        Category(id: 'rent', name: 'Rent', kind: CategoryKind.expense),
      ],
    );
    BudgetPlan plan(List<BudgetAllocation> allocations) => BudgetPlan(
      id: 'p',
      name: 'Every dollar',
      mode: BudgetMode.zeroBased,
      schedule: PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2026-07-01'),
        timezone: 'Australia/Sydney',
      ),
      versions: [
        BudgetVersion(
          id: 'v1',
          effectiveFrom: d('2026-07-01'),
          income: m('1000.00'),
          allocations: allocations,
        ),
      ],
    );

    test('every dollar assigned to categories, goals and debt balances', () {
      final balanced = plan([
        BudgetAllocation.category('rent', m('600.00')),
        BudgetAllocation.goal('holiday', m('300.00')),
        BudgetAllocation.loanPrincipal('loan', m('100.00')),
      ]);
      final check = checkZeroBased(balanced.versions.single);
      expect(check.state, ZeroBasedState.balanced);
      expect(check.isError, isFalse);
      expect(check.assigned, m('1000.00'));
      final evaluation = BudgetEvaluator(
        plan: balanced,
        ledger: LedgerProjection(chart, const []),
      ).evaluateAt(d('2026-07-10'));
      expect(evaluation.zeroBased!.state, ZeroBasedState.balanced);
    });

    test('unassigned money is an error, not a buffer', () {
      final short = plan([BudgetAllocation.category('rent', m('950.00'))]);
      final evaluation = BudgetEvaluator(
        plan: short,
        ledger: LedgerProjection(chart, const []),
      ).evaluateAt(d('2026-07-10'));
      final check = evaluation.zeroBased!;
      expect(check.state, ZeroBasedState.unassigned);
      expect(check.isError, isTrue);
      expect(check.difference, m('50.00'));

      final over = checkZeroBased(
        plan([BudgetAllocation.category('rent', m('1050.00'))]).versions.single,
      );
      expect(over.state, ZeroBasedState.overAssigned);
      expect(over.difference, m('-50.00'));
    });

    test('approved adjustments count as assigned money in a period', () {
      final p = plan([BudgetAllocation.category('rent', m('950.00'))]);
      final evaluation = BudgetEvaluator(
        plan: p,
        ledger: LedgerProjection(chart, const []),
        adjustments: [
          BudgetAdjustment(
            id: 'a',
            planId: 'p',
            targetId: 'rent',
            periodStart: d('2026-07-01'),
            amount: m('50.00'),
          ),
        ],
      ).evaluateAt(d('2026-07-10'));
      expect(evaluation.zeroBased!.state, ZeroBasedState.balanced);
    });

    test('other modes have no zero-based check; groups are rejected', () {
      final groups = BudgetPlan(
        id: 'g',
        name: 'Categories',
        mode: BudgetMode.categoryOnly,
        schedule: PeriodSchedule(
          cycle: PeriodCycle.month,
          anchor: d('2026-07-01'),
          timezone: 'Australia/Sydney',
        ),
        versions: const [],
      );
      expect(
        BudgetEvaluator(
          plan: groups,
          ledger: LedgerProjection(chart, const []),
        ).evaluateAt(d('2026-07-10')).zeroBased,
        isNull,
      );
      expect(
        () => BudgetPlan(
          id: 'z',
          name: 'z',
          mode: BudgetMode.zeroBased,
          schedule: groups.schedule,
          versions: [
            BudgetVersion(
              id: 'v',
              effectiveFrom: d('2026-07-01'),
              income: m('1.00'),
              groups: const [
                BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
              ],
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('the mode round-trips through JSON', () {
      final p = plan([BudgetAllocation.category('rent', m('1000.00'))]);
      final back = budgetPlanFromJson(budgetPlanToJson(p), aud);
      expect(back.mode, BudgetMode.zeroBased);
    });
  });
}
