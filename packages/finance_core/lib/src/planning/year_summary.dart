import '../documents/exports/csv_writer.dart';
import '../ledger/accounts.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import 'date_range.dart';
import 'ledger_reports.dart';

/// A year's figures as CSV, from the same reports the app shows, so the two
/// always agree: totals, spending by category and by tag, and what was owed at
/// the end of [year]. It records what happened and works nothing out for tax.
String yearSummaryCsv(LedgerProjection ledger, DateRange year) {
  final zero = Money.zero(ledger.chart.currency);
  final months = incomeVsExpenses(ledger, year).rows;
  Money total(String column) =>
      months.fold(zero, (sum, row) => sum + row.amount(column));
  List<String> line(String section, String item, Money amount) => [
    section,
    sanitiseCsvValue(item),
    amount.toDecimalString(),
  ];
  return encodeCsv([
    const ['Section', 'Item', 'Amount'],
    line('Totals', 'Income', total('income')),
    line('Totals', 'Expenses', total('expenses')),
    line('Totals', 'Net', total('net')),
    for (final row in spendingByCategory(ledger, year).rows)
      line('Spending by category', row.label, row.amount('spending')),
    for (final row in spendingByTag(ledger, year).rows)
      line('Spending by tag', row.label, row.amount('spending')),
    line(
      'Owed to you',
      'At end of year',
      ledger.ledgerBalance(
        SystemAccounts.reimbursementReceivable,
        asOf: year.end,
      ),
    ),
  ]);
}
