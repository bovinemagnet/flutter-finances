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
    ],
    categories: const [
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
      Category(id: 'housing', name: 'Housing', kind: CategoryKind.expense),
    ],
  );
  final factory = JournalFactory(chart);
  Journal expense(String id, String category, String amount, String date) =>
      factory.build(
        TransactionDraft(
          id: id,
          type: TransactionType.expense,
          accountId: 'bank',
          amount: m(amount),
          effectiveDate: d(date),
          splits: [Split(category, m(amount))],
        ),
      );
  final opening = factory.build(
    TransactionDraft(
      id: 'o1',
      type: TransactionType.openingBalance,
      accountId: 'bank',
      amount: m('500.00'),
      effectiveDate: d('2026-07-01'),
    ),
  );
  final journals = [
    opening,
    expense('e1', 'dining', '150.00', '2026-07-02'),
    expense('e2', 'dining', '20.00', '2026-07-03'),
    expense('e3', 'housing', '20.00', '2026-07-03'),
  ];
  final ledger = LedgerProjection(chart, journals);
  final plan = BudgetPlan(
    id: 'p',
    name: 'Budget',
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
        income: m('1000.00'),
        allocations: [
          BudgetAllocation.category('dining', m('100.00')),
          BudgetAllocation.category('housing', m('100.00')),
        ],
      ),
    ],
  );
  final period = DateRange(d('2026-07-01'), d('2026-07-31'));

  List<Insight> generate() {
    final evaluation = BudgetEvaluator(
      plan: plan,
      ledger: ledger,
    ).evaluateAt(d('2026-07-05'));
    final forecast = buildCashForecast(
      ledger: ledger,
      today: d('2026-07-05'),
      horizonDays: 30,
      schedules: [
        RecurringSchedule(
          id: 'rent',
          name: 'Rent',
          kind: ScheduleKind.expense,
          recurrence: Recurrence(
            frequency: Frequency.monthly,
            start: d('2026-07-20'),
          ),
          amount: m('400.00'),
          accountId: 'bank',
        ),
      ],
    );
    return generateInsights(
      period: period,
      budget: evaluation,
      forecast: forecast,
      lowCashThreshold: m('100.00'),
      ledger: ledger,
      unreviewedJournalIds: {'e2', 'e3'},
      receiptJournalIds: {'e2'},
      missingReceiptThreshold: m('100.00'),
      duplicateCandidates: [('e3', 'e2')],
    );
  }

  test('each rule explains its trigger, entries and period (REP 03)', () {
    final insights = generate();
    expect(insights.map((i) => i.key), [
      'overBudget:dining:2026-07-01',
      'lowCash:2026-07-20',
      'unreviewed:2026-07-01..2026-07-31',
      'missingReceipt:e1',
      'possibleDuplicate:e2|e3',
    ]);
    final over = insights.first;
    expect(over.rule, InsightRule.overBudget);
    expect(over.entryIds, ['e1', 'e2']);
    expect(over.amount, m('70.00'));
    expect(over.trigger, contains('over budget'));
    expect(over.period, period);
    final low = insights[1];
    expect(low.amount, m('-90.00'));
    expect(low.entryIds, ['rent@2026-07-20']);
    expect(insights[2].entryIds, ['e2', 'e3']);
    expect(insights[3].entryIds, ['e1']);
    expect(insights[4].entryIds, ['e2', 'e3']);
  });

  test('dismiss, snooze and disable', () {
    final insights = generate();
    final visible = visibleInsights(
      insights,
      today: d('2026-07-05'),
      states: [
        const InsightState(
          id: 's1',
          insightKey: 'missingReceipt:e1',
          dismissed: true,
        ),
        InsightState(
          id: 's2',
          insightKey: 'lowCash:2026-07-20',
          snoozedUntil: d('2026-07-08'),
        ),
      ],
      settings: [
        const InsightRuleSetting(
          id: 'r1',
          rule: InsightRule.possibleDuplicate,
          enabled: false,
        ),
      ],
    );
    expect(visible.map((i) => i.rule), [
      InsightRule.overBudget,
      InsightRule.unreviewed,
    ]);
    final later = visibleInsights(
      insights,
      today: d('2026-07-08'),
      states: [
        InsightState(
          id: 's2',
          insightKey: 'lowCash:2026-07-20',
          snoozedUntil: d('2026-07-08'),
        ),
      ],
    );
    expect(later.map((i) => i.rule), contains(InsightRule.lowCash));
  });

  test('insights never move money or change budgets', () {
    final before = ledger.displayBalance('bank');
    generate();
    expect(ledger.journals, hasLength(journals.length));
    expect(ledger.displayBalance('bank'), before);
    expect(plan.versions.single.allocationFor('dining')!.planned, m('100.00'));
  });
}
