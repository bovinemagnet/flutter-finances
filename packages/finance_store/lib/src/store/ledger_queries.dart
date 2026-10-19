import 'package:finance_core/finance_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// Balances and totals aggregated in SQL over the typed postings table.
///
/// The definitions match [LedgerProjection] exactly (REP 04): posted and
/// reversed journals form the posted ledger, pending journals only count
/// when asked, drafts and deleted journals never count. Each posting
/// carries its journal's ledger state and effective date, so every query
/// here is a covering-index scan. Nothing is stored as a balance; every
/// figure is derived from journals (SYNC 04).
class LedgerQueries {
  LedgerQueries(this.db, this.currency);

  final Database db;
  final Currency currency;

  String _states({required bool includePending}) => includePending
      ? "ledger_state IN ('posted', 'pending')"
      : "ledger_state = 'posted'";

  Money _money(Object? value) => Money((value as int?) ?? 0, currency);

  Money _sum(String where, List<Object?> args) => _money(
    db
        .select('SELECT SUM(amount_minor) FROM postings WHERE $where', args)
        .first
        .values
        .first,
  );

  /// Signed ledger balance (debit positive) of any ledger account.
  Money ledgerBalance(
    String ledgerAccountId, {
    LocalDate? asOf,
    bool includePending = false,
  }) => _sum(
    'account_id = ? AND ${_states(includePending: includePending)}'
    '${asOf == null ? '' : ' AND effective_date <= ?'}',
    [ledgerAccountId, ?asOf?.toString()],
  );

  /// Ledger balances of every ledger account with postings.
  Map<String, Money> ledgerBalances({
    LocalDate? asOf,
    bool includePending = false,
  }) {
    final rows = db.select(
      'SELECT account_id, SUM(amount_minor) AS total FROM postings '
      'WHERE ${_states(includePending: includePending)}'
      '${asOf == null ? '' : ' AND effective_date <= ?'} '
      'GROUP BY account_id',
      [?asOf?.toString()],
    );
    return {
      for (final r in rows) r['account_id'] as String: _money(r['total']),
    };
  }

  Money _kindTotal(String kind, LocalDate from, LocalDate to, String state) {
    final total = _sum(
      "ledger_state = '$state' AND effective_date BETWEEN ? AND ? AND "
      'account_id IN (SELECT id FROM categories WHERE kind = ? AND deleted = 0)',
      [from.toString(), to.toString(), kind],
    );
    return kind == 'income' ? -total : total;
  }

  /// Net posted spending in the period; refunds reduce it.
  Money expenses(LocalDate from, LocalDate to) =>
      _kindTotal('expense', from, to, 'posted');

  /// Net posted income in the period.
  Money income(LocalDate from, LocalDate to) =>
      _kindTotal('income', from, to, 'posted');

  Money pendingExpenses(LocalDate from, LocalDate to) =>
      _kindTotal('expense', from, to, 'pending');

  /// Spending and earning both positive; refunds reduce spending.
  Money categoryNet(
    String categoryId,
    LocalDate from,
    LocalDate to, {
    bool pending = false,
    required bool isIncome,
  }) {
    final total = _sum(
      "account_id = ? AND ledger_state = '${pending ? 'pending' : 'posted'}' "
      'AND effective_date BETWEEN ? AND ?',
      [categoryId, from.toString(), to.toString()],
    );
    return isIncome ? -total : total;
  }

  /// Net posted totals of every category over the period, signed like
  /// [categoryNet].
  Map<String, Money> categoryTotals(LocalDate from, LocalDate to) {
    final rows = db.select(
      'SELECT c.id, c.kind, SUM(p.amount_minor) AS total FROM postings p '
      'JOIN categories c ON c.id = p.account_id '
      "WHERE p.ledger_state = 'posted' AND p.effective_date BETWEEN ? AND ? "
      'GROUP BY c.id',
      [from.toString(), to.toString()],
    );
    return {
      for (final r in rows)
        r['id'] as String: r['kind'] == 'income'
            ? -_money(r['total'])
            : _money(r['total']),
    };
  }
}
