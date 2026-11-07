import 'package:meta/meta.dart';

import '../../ledger/accounts.dart';
import '../../ledger/journal.dart';
import '../../money/money.dart';
import '../../planning/report.dart';
import '../../time/local_date.dart';
import 'csv_writer.dart';

/// Which entries a transaction export contains (EXP 01).
@immutable
class TransactionExportFilter {
  const TransactionExportFilter({
    this.from,
    this.to,
    this.accountIds = const {},
    this.includePending = false,
    this.includeCorrections = false,
  });

  final LocalDate? from;
  final LocalDate? to;

  /// Only entries touching these accounts; empty means all.
  final Set<String> accountIds;
  final bool includePending;

  /// Include corrected originals and their reversal journals. They cancel
  /// out, so the default leaves them out and shows effective entries only.
  final bool includeCorrections;
}

const transactionExportHeader = [
  'Date',
  'Account',
  'Payee',
  'Category',
  'Amount',
  'Currency',
  'Type',
  'Status',
  'Notes',
  'Tags',
  'Owed by',
  'Journal ID',
];

/// Exports entries as CSV, one row per category line (so split entries
/// sum correctly) or, for entries without categories such as transfers,
/// one row per account line, the entry's own account first. Amounts are
/// signed from the account's point of view (negative is money out) and
/// written as plain decimals; every text field is formula-sanitised.
String exportTransactionsCsv(
  Iterable<Journal> journals,
  Chart chart, {
  TransactionExportFilter filter = const TransactionExportFilter(),
}) {
  final selected =
      journals.where((j) {
        final statusOk =
            j.status == JournalStatus.posted ||
            (filter.includePending && j.status == JournalStatus.pending) ||
            (filter.includeCorrections && j.status == JournalStatus.reversed);
        if (!statusOk) return false;
        if (j.type == TransactionType.reversal && !filter.includeCorrections) {
          return false;
        }
        if (filter.from != null && j.effectiveDate < filter.from!) return false;
        if (filter.to != null && j.effectiveDate > filter.to!) return false;
        if (filter.accountIds.isNotEmpty &&
            !j.postings.any(
              (p) => filter.accountIds.contains(p.ledgerAccountId),
            )) {
          return false;
        }
        return true;
      }).toList()..sort((a, b) {
        final byDate = a.effectiveDate.compareTo(b.effectiveDate);
        if (byDate != 0) return byDate;
        final byEntered = a.enteredAt.compareTo(b.enteredAt);
        return byEntered != 0 ? byEntered : a.id.compareTo(b.id);
      });

  String accountName(String? id) =>
      id != null && chart.hasAccount(id) ? chart.account(id).name : id ?? '';

  final rows = <List<String>>[transactionExportHeader];
  for (final journal in selected) {
    List<String> row(String account, String category, Money amount) => [
      journal.effectiveDate.toString(),
      sanitiseCsvValue(account),
      sanitiseCsvValue(journal.payee ?? ''),
      sanitiseCsvValue(category),
      amount.toDecimalString(),
      amount.currency.code,
      sanitiseCsvValue(journal.type.name),
      sanitiseCsvValue(journal.status.name),
      sanitiseCsvValue(journal.notes ?? ''),
      sanitiseCsvValue((journal.tags.toList()..sort()).join('; ')),
      sanitiseCsvValue(journal.owedBy ?? ''),
      sanitiseCsvValue(journal.id),
    ];

    final categoryLines = journal.postings
        .where((p) => chart.hasCategory(p.ledgerAccountId))
        .toList();
    if (categoryLines.isNotEmpty) {
      if (filter.accountIds.isNotEmpty &&
          !filter.accountIds.contains(journal.accountId)) {
        continue;
      }
      for (final line in categoryLines) {
        rows.add(
          row(
            accountName(journal.accountId),
            chart.category(line.ledgerAccountId).name,
            -line.amount,
          ),
        );
      }
      continue;
    }
    final accountLines =
        journal.postings
            .where((p) => chart.hasAccount(p.ledgerAccountId))
            .toList()
          ..sort((a, b) {
            final aOwn = a.ledgerAccountId == journal.accountId ? 0 : 1;
            final bOwn = b.ledgerAccountId == journal.accountId ? 0 : 1;
            return aOwn.compareTo(bOwn);
          });
    for (final line in accountLines) {
      if (filter.accountIds.isNotEmpty &&
          !filter.accountIds.contains(line.ledgerAccountId)) {
        continue;
      }
      rows.add(row(accountName(line.ledgerAccountId), '', line.amount));
    }
  }
  return encodeCsv(rows);
}

/// Exports report rows (EXP 01). [Money] becomes a plain decimal and
/// numbers, dates and booleans are written as they are; strings and
/// anything else are formula-sanitised; null is empty.
String exportReportCsv(List<String> headers, Iterable<List<Object?>> rows) =>
    encodeCsv([
      [for (final h in headers) sanitiseCsvValue(h)],
      for (final row in rows)
        [
          for (final cell in row)
            switch (cell) {
              null => '',
              Money value => value.toDecimalString(),
              int value => value.toString(),
              bool value => value.toString(),
              LocalDate value => value.toString(),
              _ => sanitiseCsvValue(cell.toString()),
            },
        ],
    ]);

/// Exports [report] with the same rows and figures as its table.
String exportReportAsCsv(Report report) => exportReportCsv(
  [report.keyLabel, for (final column in report.columns) column.label],
  [
    for (final row in report.rows)
      [
        row.label,
        for (final column in report.columns)
          switch (column.kind) {
            ReportValueKind.money => row.amounts[column.key],
            ReportValueKind.count => row.counts[column.key] ?? 0,
          },
      ],
  ],
);

/// A file name saying which report this is, for when, and whether it includes
/// unsynced changes (REP 04), so that stays known once the file leaves the app.
String reportExportName(Report report, {required LocalDate today}) {
  final title = report.title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final range = report.range;
  final date = range != null
      ? '${range.start}-to-${range.end}'
      : '${report.asOf ?? today}';
  final unsynced = report.includesUnsyncedChanges ? '-includes-unsynced' : '';
  return '$title-$date$unsynced.csv';
}
