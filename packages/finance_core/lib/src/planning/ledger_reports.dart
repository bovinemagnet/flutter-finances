import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'date_range.dart';
import 'report.dart';

// Reports over the posted ledger (posted and reversed journals plus their
// reversals), using the same definitions as LedgerProjection so reports,
// dashboard and exports agree (REP 04). Journal ids are listed in effective
// date order, ties in ledger order.

List<Journal> _posted(LedgerProjection ledger, {DateRange? range}) {
  final indexed = <(int, Journal)>[];
  var i = 0;
  for (final journal in ledger.journals) {
    if (journal.status.inPostedLedger &&
        (range == null || range.contains(journal.effectiveDate))) {
      indexed.add((i, journal));
    }
    i++;
  }
  indexed.sort((a, b) {
    final byDate = a.$2.effectiveDate.compareTo(b.$2.effectiveDate);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

int _monthIndex(LocalDate date) => date.year * 12 + date.month;

/// Income, expenses and net per calendar month of [range].
Report incomeVsExpenses(
  LedgerProjection ledger,
  DateRange range, {
  bool includesUnsyncedChanges = false,
}) {
  final chart = ledger.chart;
  final months = range.months();
  final first = _monthIndex(range.start);
  final income = List<int>.filled(months.length, 0);
  final expenses = List<int>.filled(months.length, 0);
  final ids = List.generate(months.length, (_) => <String>[]);
  for (final journal in _posted(ledger, range: range)) {
    final slot = _monthIndex(journal.effectiveDate) - first;
    var touched = false;
    for (final p in journal.postings) {
      final kind = chart.kindOf(p.ledgerAccountId);
      if (kind == LedgerKind.income) {
        income[slot] -= p.amount.minor;
        touched = true;
      } else if (kind == LedgerKind.expense) {
        expenses[slot] += p.amount.minor;
        touched = true;
      }
    }
    if (touched) ids[slot].add(journal.id);
  }
  Money money(int minor) => Money(minor, chart.currency);
  return Report(
    title: 'Income and expenses',
    keyLabel: 'Month',
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [
      ReportColumn('income', 'Income'),
      ReportColumn('expenses', 'Expenses'),
      ReportColumn('net', 'Net'),
    ],
    rows: [
      for (var i = 0; i < months.length; i++)
        ReportRow(
          key: months[i].start.toString().substring(0, 7),
          label: months[i].start.toString().substring(0, 7),
          amounts: {
            'income': money(income[i]),
            'expenses': money(expenses[i]),
            'net': money(income[i] - expenses[i]),
          },
          journalIds: ids[i],
        ),
    ],
  );
}

Report _spendingBy(
  LedgerProjection ledger,
  DateRange range, {
  required String title,
  required String keyLabel,
  required bool includesUnsyncedChanges,
  required Iterable<(String key, String label, int minor)> Function(Journal)
  keysOf,
}) {
  final totals = <String, int>{};
  final labels = <String, String>{};
  final ids = <String, List<String>>{};
  for (final journal in _posted(ledger, range: range)) {
    for (final (key, label, minor) in keysOf(journal)) {
      totals[key] = (totals[key] ?? 0) + minor;
      labels[key] = label;
      final list = ids.putIfAbsent(key, () => []);
      if (list.isEmpty || list.last != journal.id) list.add(journal.id);
    }
  }
  final keys = totals.keys.toList()
    ..sort((a, b) {
      final byAmount = totals[b]!.compareTo(totals[a]!);
      return byAmount != 0 ? byAmount : a.compareTo(b);
    });
  return Report(
    title: title,
    keyLabel: keyLabel,
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [ReportColumn('spending', 'Spending')],
    rows: [
      for (final key in keys)
        ReportRow(
          key: key,
          label: labels[key]!,
          amounts: {'spending': Money(totals[key]!, ledger.chart.currency)},
          journalIds: ids[key]!,
        ),
    ],
  );
}

/// Net spending per expense category (refunds reduce it), largest first.
Report spendingByCategory(
  LedgerProjection ledger,
  DateRange range, {
  bool includesUnsyncedChanges = false,
}) {
  final chart = ledger.chart;
  return _spendingBy(
    ledger,
    range,
    title: 'Spending by category',
    keyLabel: 'Category',
    includesUnsyncedChanges: includesUnsyncedChanges,
    keysOf: (journal) => [
      for (final p in journal.postings)
        if (chart.kindOf(p.ledgerAccountId) == LedgerKind.expense)
          (
            p.ledgerAccountId,
            chart.category(p.ledgerAccountId).name,
            p.amount.minor,
          ),
    ],
  );
}

/// Net spending per merchant or payee, largest first. Entries without a
/// payee share the empty key, labelled `No payee`.
Report spendingByPayee(
  LedgerProjection ledger,
  DateRange range, {
  bool includesUnsyncedChanges = false,
}) {
  final chart = ledger.chart;
  return _spendingBy(
    ledger,
    range,
    title: 'Spending by merchant',
    keyLabel: 'Merchant',
    includesUnsyncedChanges: includesUnsyncedChanges,
    keysOf: (journal) {
      var minor = 0;
      var touched = false;
      for (final p in journal.postings) {
        if (chart.kindOf(p.ledgerAccountId) == LedgerKind.expense) {
          minor += p.amount.minor;
          touched = true;
        }
      }
      final payee = journal.payee ?? '';
      return touched
          ? [(payee, payee.isEmpty ? 'No payee' : payee, minor)]
          : const [];
    },
  );
}

/// Each account's balance as a user reads it on [asOf] (all time when
/// null), with the journals that make it up.
Report accountBalances(
  LedgerProjection ledger, {
  LocalDate? asOf,
  bool includesUnsyncedChanges = false,
}) {
  final chart = ledger.chart;
  final ids = <String, List<String>>{};
  final totals = <String, int>{};
  for (final journal in _posted(ledger)) {
    if (asOf != null && journal.effectiveDate > asOf) continue;
    for (final p in journal.postings) {
      if (!chart.hasAccount(p.ledgerAccountId)) continue;
      totals[p.ledgerAccountId] =
          (totals[p.ledgerAccountId] ?? 0) + p.amount.minor;
      final list = ids.putIfAbsent(p.ledgerAccountId, () => []);
      if (list.isEmpty || list.last != journal.id) list.add(journal.id);
    }
  }
  return Report(
    title: 'Account balances',
    keyLabel: 'Account',
    asOf: asOf,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [ReportColumn('balance', 'Balance')],
    rows: [
      for (final account in chart.accounts)
        ReportRow(
          key: account.id,
          label: account.name,
          amounts: {
            'balance': Money(
              (account.type.isLiability ? -1 : 1) * (totals[account.id] ?? 0),
              chart.currency,
            ),
          },
          journalIds: ids[account.id] ?? const [],
        ),
    ],
  );
}

/// Net worth at the end of each calendar month of [range] (the range end
/// for a partial last month), as [LedgerProjection.netWorth] defines it.
/// Each point lists the journals that changed net worth in its month.
Report netWorthHistory(
  LedgerProjection ledger,
  DateRange range, {
  bool includesUnsyncedChanges = false,
}) {
  final chart = ledger.chart;
  final included = {
    for (final a in chart.accounts)
      if (a.includeInNetWorth) a.id,
    SystemAccounts.reimbursementReceivable,
  };
  final months = range.months();
  final first = _monthIndex(range.start);
  final deltas = List<int>.filled(months.length, 0);
  final ids = List.generate(months.length, (_) => <String>[]);
  var opening = 0;
  for (final journal in _posted(ledger)) {
    if (journal.effectiveDate > range.end) break;
    var delta = 0;
    var touched = false;
    for (final p in journal.postings) {
      if (included.contains(p.ledgerAccountId)) {
        delta += p.amount.minor;
        touched = true;
      }
    }
    if (journal.effectiveDate < range.start) {
      opening += delta;
    } else if (touched) {
      final slot = _monthIndex(journal.effectiveDate) - first;
      deltas[slot] += delta;
      ids[slot].add(journal.id);
    }
  }
  var running = opening;
  return Report(
    title: 'Net worth',
    keyLabel: 'Date',
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [ReportColumn('netWorth', 'Net worth')],
    rows: [
      for (var i = 0; i < months.length; i++)
        ReportRow(
          key: months[i].end.toString(),
          label: months[i].end.toString(),
          amounts: {'netWorth': Money(running += deltas[i], chart.currency)},
          journalIds: ids[i],
        ),
    ],
  );
}

/// Cash flow of an account set (REP 01). A journal whose postings to the
/// set net to zero is a transfer within the set; otherwise its net effect
/// on the set is an inflow or outflow crossing the boundary.
Report cashFlow(
  LedgerProjection ledger,
  DateRange range, {
  required Set<String> accountIds,
  bool includesUnsyncedChanges = false,
}) {
  var inflows = 0;
  var outflows = 0;
  var internal = 0;
  final inIds = <String>[];
  final outIds = <String>[];
  final internalIds = <String>[];
  for (final journal in _posted(ledger, range: range)) {
    var net = 0;
    var moved = 0;
    var touched = false;
    for (final p in journal.postings) {
      if (!accountIds.contains(p.ledgerAccountId)) continue;
      touched = true;
      net += p.amount.minor;
      if (p.amount.minor > 0) moved += p.amount.minor;
    }
    if (!touched) continue;
    if (net == 0) {
      if (moved == 0) continue;
      internal += moved;
      internalIds.add(journal.id);
    } else if (net > 0) {
      inflows += net;
      inIds.add(journal.id);
    } else {
      outflows -= net;
      outIds.add(journal.id);
    }
  }
  Money money(int minor) => Money(minor, ledger.chart.currency);
  final boundaryIds = {...inIds, ...outIds};
  return Report(
    title: 'Cash flow',
    keyLabel: 'Flow',
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [ReportColumn('amount', 'Amount')],
    rows: [
      ReportRow(
        key: 'inflows',
        label: 'Money in',
        amounts: {'amount': money(inflows)},
        journalIds: inIds,
      ),
      ReportRow(
        key: 'outflows',
        label: 'Money out',
        amounts: {'amount': money(outflows)},
        journalIds: outIds,
      ),
      ReportRow(
        key: 'internalTransfers',
        label: 'Transfers between these accounts',
        amounts: {'amount': money(internal)},
        journalIds: internalIds,
      ),
      ReportRow(
        key: 'net',
        label: 'Net',
        amounts: {'amount': money(inflows - outflows)},
        journalIds: [
          for (final j in _posted(ledger, range: range))
            if (boundaryIds.contains(j.id)) j.id,
        ],
      ),
    ],
  );
}

/// Posted purchases in [range] with and without a receipt.
/// [receiptJournalIds] are the journals that have at least one receipt.
Report receiptCoverage(
  LedgerProjection ledger,
  DateRange range, {
  required Set<String> receiptJournalIds,
  bool includesUnsyncedChanges = false,
}) {
  final covered = <String>[];
  final missing = <String>[];
  var coveredMinor = 0;
  var missingMinor = 0;
  for (final journal in purchasesIn(ledger, range)) {
    final minor = journal.amount?.minor ?? 0;
    if (receiptJournalIds.contains(journal.id)) {
      covered.add(journal.id);
      coveredMinor += minor;
    } else {
      missing.add(journal.id);
      missingMinor += minor;
    }
  }
  Money money(int minor) => Money(minor, ledger.chart.currency);
  return Report(
    title: 'Receipt coverage',
    keyLabel: 'Receipts',
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: const [
      ReportColumn('entries', 'Entries', kind: ReportValueKind.count),
      ReportColumn('amount', 'Amount'),
    ],
    rows: [
      ReportRow(
        key: 'covered',
        label: 'With receipt',
        counts: {'entries': covered.length},
        amounts: {'amount': money(coveredMinor)},
        journalIds: covered,
      ),
      ReportRow(
        key: 'missing',
        label: 'Without receipt',
        counts: {'entries': missing.length},
        amounts: {'amount': money(missingMinor)},
        journalIds: missing,
      ),
    ],
  );
}

/// Posted (not reversed) purchases in [range], in date order: expenses and
/// reimbursable expenses.
List<Journal> purchasesIn(LedgerProjection ledger, DateRange range) => [
  for (final journal in _posted(ledger, range: range))
    if (journal.status == JournalStatus.posted &&
        (journal.type == TransactionType.expense ||
            journal.type == TransactionType.reimbursableExpense))
      journal,
];
