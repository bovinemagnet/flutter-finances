import '../money/money.dart';
import '../time/local_date.dart';
import 'accounts.dart';
import 'journal.dart';

/// Balances and totals derived from journals.
///
/// Balances are never stored as editable truth (SYNC 04); every figure here
/// is recomputed from accepted journals.
class LedgerProjection {
  LedgerProjection(this.chart, Iterable<Journal> journals)
    : journals = List.unmodifiable(journals);

  final Chart chart;
  final List<Journal> journals;

  Money get _zero => Money.zero(chart.currency);

  bool _counts(Journal journal, {required bool includePending}) =>
      journal.status.inPostedLedger ||
      (includePending && journal.status == JournalStatus.pending);

  bool _inRange(LocalDate date, LocalDate? from, LocalDate? to) =>
      (from == null || date >= from) && (to == null || date <= to);

  Money _sum(
    bool Function(Journal) includeJournal,
    bool Function(Posting) includePosting,
  ) {
    var total = _zero;
    for (final journal in journals) {
      if (!includeJournal(journal)) continue;
      for (final posting in journal.postings) {
        if (includePosting(posting)) total += posting.amount;
      }
    }
    return total;
  }

  /// Signed ledger balance (debit positive) of any ledger account.
  Money ledgerBalance(
    String ledgerAccountId, {
    LocalDate? asOf,
    bool includePending = false,
  }) => _sum(
    (j) =>
        _counts(j, includePending: includePending) &&
        _inRange(j.effectiveDate, null, asOf),
    (p) => p.ledgerAccountId == ledgerAccountId,
  );

  /// Balance as a user reads it: money held, or money owed for liabilities.
  Money displayBalance(
    String accountId, {
    LocalDate? asOf,
    bool includePending = false,
  }) {
    final balance = ledgerBalance(
      accountId,
      asOf: asOf,
      includePending: includePending,
    );
    return chart.account(accountId).type.isLiability ? -balance : balance;
  }

  Money _kindTotal(
    LedgerKind kind,
    LocalDate from,
    LocalDate to,
    bool Function(Journal) include,
  ) {
    final total = _sum(
      (j) => include(j) && _inRange(j.effectiveDate, from, to),
      (p) => chart.kindOf(p.ledgerAccountId) == kind,
    );
    return kind == LedgerKind.income ? -total : total;
  }

  /// Net posted spending in the period; refunds reduce it.
  Money expenses(LocalDate from, LocalDate to) =>
      _kindTotal(LedgerKind.expense, from, to, (j) => j.status.inPostedLedger);

  /// Net posted income in the period.
  Money income(LocalDate from, LocalDate to) =>
      _kindTotal(LedgerKind.income, from, to, (j) => j.status.inPostedLedger);

  Money pendingExpenses(LocalDate from, LocalDate to) => _kindTotal(
    LedgerKind.expense,
    from,
    to,
    (j) => j.status == JournalStatus.pending,
  );

  /// Net amount for a category in the period, signed so that spending and
  /// earning are both positive.
  Money categoryNet(
    String categoryId,
    LocalDate from,
    LocalDate to, {
    bool pending = false,
  }) {
    final total = _sum(
      (j) =>
          (pending
              ? j.status == JournalStatus.pending
              : j.status.inPostedLedger) &&
          _inRange(j.effectiveDate, from, to),
      (p) => p.ledgerAccountId == categoryId,
    );
    return chart.category(categoryId).kind == CategoryKind.income
        ? -total
        : total;
  }

  /// Assets less liabilities for accounts included in net worth, plus
  /// money owed to the user through reimbursements.
  Money netWorth({LocalDate? asOf}) {
    var total = ledgerBalance(
      SystemAccounts.reimbursementReceivable,
      asOf: asOf,
    );
    for (final account in chart.accounts) {
      if (account.includeInNetWorth) {
        total += ledgerBalance(account.id, asOf: asOf);
      }
    }
    return total;
  }

  Money liquidMoney({LocalDate? asOf}) {
    var total = _zero;
    for (final account in chart.accounts) {
      if (account.type.isLiquid && account.includeInNetWorth) {
        total += ledgerBalance(account.id, asOf: asOf);
      }
    }
    return total;
  }

  Money liabilitiesOwed({LocalDate? asOf}) {
    var total = _zero;
    for (final account in chart.accounts) {
      if (account.type.isLiability && account.includeInNetWorth) {
        total += displayBalance(account.id, asOf: asOf);
      }
    }
    return total;
  }

  Iterable<Journal> journalsForAccount(String accountId) => journals.where(
    (j) => j.postings.any((p) => p.ledgerAccountId == accountId),
  );
}
