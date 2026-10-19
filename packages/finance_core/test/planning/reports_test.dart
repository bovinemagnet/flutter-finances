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
      Account(id: 'savings', name: 'Savings', type: AccountType.savings),
      Account(id: 'card', name: 'Card', type: AccountType.creditCard),
      Account(
        id: 'super',
        name: 'Super',
        type: AccountType.superannuation,
        includeInNetWorth: false,
      ),
    ],
    categories: const [
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
      Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
    ],
  );
  final factory = JournalFactory(chart);

  Journal build(
    String id,
    TransactionType type,
    String account,
    String amount,
    String date, {
    String? to,
    String? category,
    String? payee,
    JournalStatus status = JournalStatus.posted,
  }) => factory.build(
    TransactionDraft(
      id: id,
      type: type,
      accountId: account,
      counterAccountId: to,
      amount: m(amount),
      effectiveDate: d(date),
      payee: payee,
      status: status,
      splits: category == null ? const [] : [Split(category, m(amount))],
    ),
  );

  final journals = [
    build(
      'o1',
      TransactionType.openingBalance,
      'bank',
      '1000.00',
      '2026-06-30',
    ),
    build(
      'i1',
      TransactionType.income,
      'bank',
      '3000.00',
      '2026-07-01',
      category: 'salary',
      payee: 'Employer',
    ),
    build(
      'e1',
      TransactionType.expense,
      'card',
      '120.00',
      '2026-07-02',
      category: 'groceries',
      payee: 'Grocer',
    ),
    build(
      'e2',
      TransactionType.expense,
      'bank',
      '80.00',
      '2026-07-03',
      category: 'groceries',
      payee: 'Grocer',
    ),
    build(
      'e3',
      TransactionType.expense,
      'bank',
      '45.00',
      '2026-08-04',
      category: 'dining',
      payee: 'Cafe',
    ),
    build(
      'r1',
      TransactionType.refund,
      'bank',
      '20.00',
      '2026-08-05',
      category: 'groceries',
      payee: 'Grocer',
    ),
    build(
      't1',
      TransactionType.transfer,
      'bank',
      '500.00',
      '2026-07-10',
      to: 'savings',
    ),
    build(
      't2',
      TransactionType.transfer,
      'bank',
      '120.00',
      '2026-07-20',
      to: 'card',
    ),
    build(
      'p1',
      TransactionType.expense,
      'bank',
      '99.00',
      '2026-07-21',
      category: 'dining',
      status: JournalStatus.pending,
    ),
  ];
  final ledger = LedgerProjection(chart, journals);

  group('date ranges (REP 02)', () {
    test('Australian financial year runs July to June', () {
      final fy = DateRange.financialYear(2026);
      expect(fy.start, d('2026-07-01'));
      expect(fy.end, d('2027-06-30'));
      expect(DateRange.financialYearContaining(d('2027-03-01')), fy);
      expect(
        DateRange.financialYearContaining(d('2026-06-30')).start,
        d('2025-07-01'),
      );
      expect(fy.label, 'FY2026-27');
    });

    test('calendar year and custom ranges, split into months', () {
      expect(DateRange.calendarYear(2026).end, d('2026-12-31'));
      final custom = DateRange(d('2026-07-15'), d('2026-09-10'));
      expect(custom.months().map((r) => '${r.start}..${r.end}'), [
        '2026-07-15..2026-07-31',
        '2026-08-01..2026-08-31',
        '2026-09-01..2026-09-10',
      ]);
      expect(
        () => DateRange(d('2026-07-02'), d('2026-07-01')),
        throwsArgumentError,
      );
    });
  });

  group('core reports (REP 01)', () {
    final range = DateRange(d('2026-07-01'), d('2026-08-31'));

    test('income versus expenses by month with drill-through', () {
      final report = incomeVsExpenses(ledger, range);
      expect(report.columns.map((c) => c.key), ['income', 'expenses', 'net']);
      expect(report.rows.map((r) => r.key), ['2026-07', '2026-08']);
      final july = report.rows.first;
      expect(july.amount('income'), m('3000.00'));
      expect(july.amount('expenses'), m('200.00'));
      expect(july.amount('net'), m('2800.00'));
      expect(july.journalIds, ['i1', 'e1', 'e2']);
      expect(report.rows.last.amount('expenses'), m('25.00'));
      expect(report.includesUnsyncedChanges, isFalse);
    });

    test('spending by category matches the ledger definition (REP 04)', () {
      final report = spendingByCategory(ledger, range);
      expect(report.rows.map((r) => (r.key, r.amount('spending'))), [
        ('groceries', m('180.00')),
        ('dining', m('45.00')),
      ]);
      expect(report.row('groceries')!.journalIds, ['e1', 'e2', 'r1']);
      expect(
        report.rows.fold(m('0.00'), (sum, r) => sum + r.amount('spending')),
        ledger.expenses(range.start, range.end),
      );
    });

    test('spending by merchant', () {
      final report = spendingByPayee(ledger, range);
      expect(report.rows.map((r) => (r.label, r.amount('spending'))), [
        ('Grocer', m('180.00')),
        ('Cafe', m('45.00')),
      ]);
    });

    test('account balances with net worth inclusion', () {
      final report = accountBalances(ledger, asOf: d('2026-08-31'));
      expect(report.row('bank')!.amount('balance'), m('3275.00'));
      expect(report.row('card')!.amount('balance'), m('0.00'));
      expect(report.row('savings')!.journalIds, ['t1']);
    });

    test('net worth history has month-end points', () {
      final report = netWorthHistory(ledger, range);
      expect(report.rows.map((r) => (r.key, r.amount('netWorth'))), [
        ('2026-07-31', m('3800.00')),
        ('2026-08-31', m('3775.00')),
      ]);
      expect(report.rows.last.journalIds, ['e3', 'r1']);
      expect(
        report.rows.last.amount('netWorth'),
        ledger.netWorth(asOf: d('2026-08-31')),
      );
    });

    test('cash flow separates internal transfers from boundary flows', () {
      final report = cashFlow(ledger, range, accountIds: {'bank', 'savings'});
      expect(report.row('inflows')!.amount('amount'), m('3020.00'));
      expect(report.row('outflows')!.amount('amount'), m('245.00'));
      expect(report.row('outflows')!.journalIds, ['e2', 't2', 'e3']);
      expect(report.row('internalTransfers')!.amount('amount'), m('500.00'));
      expect(report.row('internalTransfers')!.journalIds, ['t1']);
      expect(report.row('net')!.amount('amount'), m('2775.00'));
      final wider = cashFlow(
        ledger,
        range,
        accountIds: {'bank', 'savings', 'card'},
      );
      expect(wider.row('internalTransfers')!.journalIds, ['t1', 't2']);
    });

    test('receipt coverage', () {
      final report = receiptCoverage(ledger, range, receiptJournalIds: {'e1'});
      expect(report.row('covered')!.count('entries'), 1);
      expect(report.row('covered')!.amount('amount'), m('120.00'));
      expect(report.row('missing')!.count('entries'), 2);
      expect(report.row('missing')!.journalIds, ['e2', 'e3']);
    });

    test('reports render as accessible tables', () {
      final table = spendingByCategory(
        ledger,
        range,
        includesUnsyncedChanges: true,
      );
      expect(table.includesUnsyncedChanges, isTrue);
      expect(table.toTable(), [
        ['Category', 'Spending'],
        ['Groceries', '180.00'],
        ['Dining', '45.00'],
      ]);
    });
  });

  group('planning reports', () {
    test('budget versus actual from an evaluation', () {
      final plan = BudgetPlan(
        id: 'p',
        name: 'Household',
        mode: BudgetMode.categoryOnly,
        schedule: PeriodSchedule(
          cycle: PeriodCycle.month,
          anchor: d('2026-07-01'),
          timezone: 'Australia/Sydney',
        ),
        versions: [
          BudgetVersion(
            id: 'v1',
            effectiveFrom: d('2026-07-01'),
            income: m('3000.00'),
            allocations: [BudgetAllocation.category('groceries', m('150.00'))],
          ),
        ],
      );
      final evaluation = BudgetEvaluator(
        plan: plan,
        ledger: ledger,
      ).evaluateAt(d('2026-07-15'));
      final report = budgetVsActual(evaluation);
      final groceries = report.row('groceries')!;
      expect(groceries.amount('planned'), m('150.00'));
      expect(groceries.amount('actual'), m('200.00'));
      expect(groceries.amount('remaining'), m('-50.00'));
      expect(groceries.journalIds, ['e1', 'e2']);
      expect(report.row('dining')!.amount('pending'), m('99.00'));
    });

    test('goal progress', () {
      final progress = goalProgress(
        Goal(id: 'g', name: 'Holiday', target: m('1000.00')),
        ledger: ledger,
        allocations: [
          SavingsAllocation(
            id: 'a',
            goalId: 'g',
            date: d('2026-07-10'),
            amount: m('500.00'),
            transferJournalId: 't1',
          ),
        ],
      );
      final report = goalProgressReport([progress]);
      expect(report.row('g')!.amount('allocated'), m('500.00'));
      expect(report.row('g')!.amount('moved'), m('500.00'));
      expect(report.row('g')!.journalIds, ['t1']);
    });
  });
}
