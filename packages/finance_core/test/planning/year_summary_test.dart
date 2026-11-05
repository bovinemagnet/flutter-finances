import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(int minor) => Money(minor, aud);
  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
    ],
    categories: const [
      Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
      Category(id: '=fun', name: '=SUM(A1)', kind: CategoryKind.expense),
      Category(id: 'pay', name: 'Pay', kind: CategoryKind.income),
    ],
  );
  final factory = JournalFactory(chart);
  final year = DateRange.financialYear(2025);

  Journal entry(
    TransactionType type,
    int minor,
    LocalDate date, {
    String? category,
    Set<String> tags = const {},
  }) => factory.build(
    TransactionDraft(
      type: type,
      accountId: 'bank',
      amount: m(minor),
      effectiveDate: date,
      splits: category == null ? const [] : [Split(category, m(minor))],
      tags: tags,
    ),
  );

  List<List<String>> rows(List<Journal> journals) {
    final csv = yearSummaryCsv(LedgerProjection(chart, journals), year);
    return [for (final line in csv.trim().split('\r\n')) line.split(',')];
  }

  List<String> row(List<List<String>> rows, String section, String item) =>
      rows.firstWhere((r) => r[0] == section && r[1] == item);

  final inYear = LocalDate(2025, 10, 1);

  test('starts with a heading row', () {
    expect(rows([]).first, ['Section', 'Item', 'Amount']);
  });

  test('totals income, expenses and net for the year', () {
    final result = rows([
      entry(TransactionType.income, 500000, inYear, category: 'pay'),
      entry(TransactionType.expense, 120000, inYear, category: 'food'),
    ]);
    expect(row(result, 'Totals', 'Income')[2], '5000.00');
    expect(row(result, 'Totals', 'Expenses')[2], '1200.00');
    expect(row(result, 'Totals', 'Net')[2], '3800.00');
  });

  test('breaks spending down by category and by tag', () {
    final result = rows([
      entry(
        TransactionType.expense,
        120000,
        inYear,
        category: 'food',
        tags: {'holiday'},
      ),
    ]);
    expect(row(result, 'Spending by category', 'Food')[2], '1200.00');
    expect(row(result, 'Spending by tag', 'holiday')[2], '1200.00');
  });

  test('leaves out entries outside the year', () {
    final result = rows([
      entry(
        TransactionType.expense,
        120000,
        LocalDate(2025, 6, 30),
        category: 'food',
        tags: {'holiday'},
      ),
      entry(
        TransactionType.expense,
        120000,
        LocalDate(2026, 7, 1),
        category: 'food',
      ),
    ]);
    expect(row(result, 'Totals', 'Expenses')[2], '0.00');
    expect(result.where((r) => r[0] == 'Spending by tag'), isEmpty);
  });

  test('includes the first and last days of the year', () {
    final result = rows([
      entry(
        TransactionType.expense,
        100,
        LocalDate(2025, 7, 1),
        category: 'food',
      ),
      entry(
        TransactionType.expense,
        200,
        LocalDate(2026, 6, 30),
        category: 'food',
      ),
    ]);
    expect(row(result, 'Totals', 'Expenses')[2], '3.00');
  });

  test('shows what was owed at the end of the year', () {
    final result = rows([
      entry(TransactionType.reimbursableExpense, 5000, inYear),
      entry(TransactionType.reimbursableExpense, 9000, LocalDate(2026, 7, 2)),
    ]);
    expect(row(result, 'Owed to you', 'At end of year')[2], '50.00');
  });

  test('money owed is not counted as an expense', () {
    final result = rows([
      entry(TransactionType.reimbursableExpense, 5000, inYear),
    ]);
    expect(row(result, 'Totals', 'Expenses')[2], '0.00');
  });

  test('a name cannot run as a spreadsheet formula', () {
    final csv = yearSummaryCsv(
      LedgerProjection(chart, [
        entry(TransactionType.expense, 100, inYear, category: '=fun'),
      ]),
      year,
    );
    expect(csv, contains("'=SUM(A1)"));
    expect(csv, isNot(contains(',=SUM(A1)')));
  });
}
