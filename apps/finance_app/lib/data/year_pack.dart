import 'dart:io';

import 'package:finance_core/finance_core.dart';

import '../format/formatters.dart';
import 'app_state.dart';

String yearPackName(DateRange year) => 'finance-${year.label}';

class YearPackResult {
  const YearPackResult({
    required this.receiptFiles,
    required this.onServerOnly,
  });

  /// Original receipt files copied into the pack.
  final int receiptFiles;

  /// Files listed in the manifest but not on this device, so not copied.
  final int onServerOnly;
}

/// Writes a record of one financial year into [folder]: every entry, the totals,
/// and the receipts that belong to the year. It records what happened and works
/// nothing out for tax.
Future<YearPackResult> writeYearPack(
  AppState state,
  Directory folder,
  DateRange year,
) async {
  await folder.create(recursive: true);
  await File('${folder.path}/transactions.csv').writeAsString(
    exportTransactionsCsv(
      state.ledger.journals,
      state.chart,
      filter: TransactionExportFilter(from: year.start, to: year.end),
    ),
  );
  await File('${folder.path}/summary.csv')
      .writeAsString(yearSummaryCsv(state.ledger, year));
  final receipts = await state.receipts.exportOriginalsWithin(
    Directory('${folder.path}/receipts'),
    year: year,
  );
  await File('${folder.path}/README.txt').writeAsString(
    'Financial year pack: ${formatDate(year.start)} to ${formatDate(year.end)}\n'
    '\n'
    'transactions.csv  Every entry in the year, with categories and tags.\n'
    'summary.csv       Income, expenses, spending by category and tag, and what '
    'you were owed at the end of the year.\n'
    'receipts/         The original receipt files, with manifest.json describing '
    'each one.\n'
    '\n'
    'An entry with more than one tag counts under each in summary.csv, so the '
    'tags can add up to more than you spent.\n'
    '\n'
    'This is a record of what you entered. It is not tax advice, and it does not '
    'work out what you can claim. Check it before relying on it.\n',
  );
  return YearPackResult(
    receiptFiles: receipts.written,
    onServerOnly: receipts.onServerOnly,
  );
}
