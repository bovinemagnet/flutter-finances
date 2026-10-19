import 'package:finance_core/finance_core.dart';

/// A small, realistic workspace built with the real domain functions.
class SampleWorld {
  SampleWorld() {
    final factory = JournalFactory(chart);
    TransactionDraft expense(
      String category,
      int minor,
      LocalDate date, {
      JournalStatus status = JournalStatus.posted,
    }) => TransactionDraft(
      type: TransactionType.expense,
      accountId: 'bank',
      amount: Money(minor, aud),
      effectiveDate: date,
      splits: [Split(category, Money(minor, aud))],
      status: status,
      payee: const {
        'groceries': 'Fresh Grocer',
        'dining': 'Corner Cafe',
      }[category],
    );
    journals = [
      factory.build(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: Money(400000, aud),
          effectiveDate: LocalDate(2026, 10, 1),
        ),
      ),
      factory.build(expense('groceries', 45000, LocalDate(2026, 10, 3))),
      factory.build(expense('dining', 32000, LocalDate(2026, 10, 10))),
      factory.build(
        expense(
          'dining',
          2500,
          LocalDate(2026, 10, 18),
          status: JournalStatus.pending,
        ),
      ),
    ];
    ledger = LedgerProjection(chart, journals);
  }

  static const aud = Currency.aud;
  final today = LocalDate(2026, 10, 19);
  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
    ],
    categories: const [
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
      Category(id: 'rent', name: 'Rent', kind: CategoryKind.expense),
    ],
  );
  late final List<Journal> journals;
  late final LedgerProjection ledger;

  late final plan = BudgetPlan(
    id: 'plan',
    name: 'Household',
    mode: BudgetMode.groups,
    schedule: PeriodSchedule(
      cycle: PeriodCycle.month,
      anchor: LocalDate(2026, 10, 1),
      timezone: 'Australia/Brisbane',
    ),
    versions: [
      BudgetVersion(
        id: 'v1',
        effectiveFrom: LocalDate(2026, 10, 1),
        income: Money(500000, aud),
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
        allocations: [
          BudgetAllocation.category(
            'groceries',
            Money(80000, aud),
            groupId: 'needs',
          ),
          BudgetAllocation.category(
            'rent',
            Money(170000, aud),
            groupId: 'needs',
          ),
          BudgetAllocation.category(
            'dining',
            Money(30000, aud),
            groupId: 'wants',
          ),
        ],
      ),
    ],
  );

  BudgetPeriodEvaluation evaluation() =>
      BudgetEvaluator(plan: plan, ledger: ledger).evaluateAt(today);

  CashForecast forecast() => buildCashForecast(ledger: ledger, today: today);

  DiscretionaryEstimate estimate() => estimateDiscretionary(
    plan: plan,
    ledger: ledger,
    today: today,
    horizonEnd: LocalDate(2026, 10, 30),
    minimumBuffer: Money(50000, aud),
  );

  String nameFor(String id) => chart.hasCategory(id)
      ? chart.category(id).name
      : chart.hasAccount(id)
      ? chart.account(id).name
      : id;
}
