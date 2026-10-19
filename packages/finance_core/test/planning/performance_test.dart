import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

/// NFR 09: planning computations over a 100,000-transaction workspace with
/// 20 accounts stay well under a second.
void main() {
  const aud = Currency.aud;
  final start = LocalDate(2022, 7, 1);
  final accounts = [
    for (var i = 0; i < 20; i++)
      Account(
        id: 'a$i',
        name: 'Account $i',
        type: i < 15 ? AccountType.transaction : AccountType.creditCard,
      ),
  ];
  final categories = [
    for (var i = 0; i < 30; i++)
      Category(id: 'c$i', name: 'Category $i', kind: CategoryKind.expense),
  ];
  final chart = Chart(
    currency: aud,
    accounts: accounts,
    categories: categories,
  );
  final journals = [
    for (var i = 0; i < 100000; i++)
      Journal(
        id: 'j$i',
        type: TransactionType.expense,
        status: i % 50 == 0 ? JournalStatus.pending : JournalStatus.posted,
        effectiveDate: start.addDays(i % 1461),
        enteredAt: DateTime.utc(2026),
        postings: [
          Posting('c${i % 30}', Money(100 + i % 9000, aud)),
          Posting('a${i % 20}', Money(-(100 + i % 9000), aud)),
        ],
        accountId: 'a${i % 20}',
        amount: Money(100 + i % 9000, aud),
        payee: 'Payee ${i % 500}',
      ),
  ];
  final ledger = LedgerProjection(chart, journals);
  final plan = BudgetPlan(
    id: 'p',
    name: 'Budget',
    mode: BudgetMode.categoryOnly,
    schedule: PeriodSchedule(
      cycle: PeriodCycle.month,
      anchor: start,
      timezone: 'Australia/Sydney',
      rollover: RolloverPolicy.signed,
    ),
    versions: [
      BudgetVersion(
        id: 'v1',
        effectiveFrom: start,
        income: Money(1000000, aud),
        allocations: [
          for (final c in categories)
            BudgetAllocation.category(c.id, Money(20000, aud)),
        ],
      ),
    ],
  );

  int timeMs(void Function() body) {
    final watch = Stopwatch()..start();
    body();
    return watch.elapsedMilliseconds;
  }

  test('budget versus actual with four years of rollover', () {
    late BudgetPeriodEvaluation evaluation;
    final ms = timeMs(() {
      evaluation = BudgetEvaluator(
        plan: plan,
        ledger: ledger,
      ).evaluateAt(LocalDate(2026, 6, 15));
      budgetVsActual(evaluation);
    });
    expect(evaluation.lines, hasLength(30));
    expect(ms, lessThan(1000), reason: 'took $ms ms');
  });

  test('90-day forecast', () {
    late CashForecast forecast;
    final ms = timeMs(() {
      forecast = buildCashForecast(
        ledger: ledger,
        today: LocalDate(2026, 6, 1),
      );
    });
    expect(forecast.days, hasLength(90));
    expect(ms, lessThan(1000), reason: 'took $ms ms');
  });

  test('financial year reports', () {
    final range = DateRange.financialYear(2025);
    final ms = timeMs(() {
      spendingByCategory(ledger, range);
      incomeVsExpenses(ledger, range);
      netWorthHistory(ledger, range);
    });
    expect(ms, lessThan(1000), reason: 'took $ms ms');
  });
}
