import 'package:meta/meta.dart';

import '../../ledger/accounts.dart';
import '../../ledger/journal.dart';
import '../../money/money.dart';
import '../../time/local_date.dart';
import '../matching/source_reconciliation.dart';
import 'csv_parse.dart';
import 'fingerprint.dart';
import 'import_batch.dart';
import 'import_errors.dart';
import 'source_record.dart';

/// How a statement row relates to what is already recorded.
enum PreviewRowStatus {
  /// Nothing like it exists; committing creates an entry by default.
  newEntry,

  /// Its fingerprint was already imported; committing creates nothing.
  duplicate,

  /// Something similar was imported (another occurrence of the same
  /// fingerprint, or the same date and amount with a different
  /// description): the user decides.
  ambiguous,

  /// An existing entry (for example one created from a receipt) has the
  /// same amount nearby: the user decides whether this row is its evidence.
  existingMatch,
}

/// Things to point out during preview (IMP 03).
enum PreviewFlag { possibleTransfer, possibleCardRepayment, receiptEntry }

@immutable
class PreviewRow {
  PreviewRow({
    required this.row,
    required this.fingerprint,
    required this.status,
    Set<PreviewFlag> flags = const {},
    List<SourceMatchProposal> proposals = const [],
    this.duplicateOf,
    this.transferCounterpart,
  }) : flags = Set.unmodifiable(flags),
       proposals = List.unmodifiable(proposals);

  final ImportRow row;
  final String fingerprint;
  final PreviewRowStatus status;
  final Set<PreviewFlag> flags;

  /// Existing entries this row may be evidence for (MATCH 03).
  final List<SourceMatchProposal> proposals;

  /// The previously imported record with the same fingerprint, or the
  /// closest one for an ambiguous row.
  final SourceRecord? duplicateOf;

  /// An entry on another account with the opposite amount nearby.
  final Journal? transferCounterpart;

  /// Rows the user must decide on before commit.
  bool get requiresDecision =>
      status == PreviewRowStatus.ambiguous ||
      status == PreviewRowStatus.existingMatch ||
      flags.contains(PreviewFlag.possibleTransfer) ||
      flags.contains(PreviewFlag.possibleCardRepayment);
}

/// A run of days with no rows, which may mean a missing statement.
@immutable
class DateGap {
  const DateGap(this.from, this.to);

  /// Last date before the gap.
  final LocalDate from;

  /// First date after the gap.
  final LocalDate to;

  int get days => from.daysUntil(to);
}

@immutable
class ImportTotals {
  const ImportTotals({
    required this.count,
    required this.credits,
    required this.debits,
  });

  final int count;

  /// Money arriving, as a positive amount.
  final Money credits;

  /// Money leaving, as a positive amount.
  final Money debits;

  Money get net => credits - debits;
}

/// A comparison with the balances printed on a statement. It reports a
/// difference only; missing transactions are never invented (IMP 03).
@immutable
class StatementCheck {
  const StatementCheck({required this.expectedNet, required this.importedNet});

  final Money expectedNet;
  final Money importedNet;

  Money get difference => expectedNet - importedNet;
  bool get balanced => difference.isZero;
}

@immutable
class ImportPreview {
  ImportPreview({
    required this.accountId,
    required this.sourceHash,
    required this.currency,
    required List<PreviewRow> rows,
    required List<ImportRowError> errors,
    required List<DateGap> dateGaps,
    this.alreadyImportedBatch,
  }) : rows = List.unmodifiable(rows),
       errors = List.unmodifiable(errors),
       dateGaps = List.unmodifiable(dateGaps);

  final String accountId;
  final String sourceHash;
  final Currency currency;
  final List<PreviewRow> rows;
  final List<ImportRowError> errors;
  final List<DateGap> dateGaps;

  /// Set when this exact file was already committed (A12).
  final ImportBatch? alreadyImportedBatch;

  ImportTotals _totals(Iterable<PreviewRow> selected) {
    var credits = 0;
    var debits = 0;
    var count = 0;
    for (final r in selected) {
      count++;
      final minor = r.row.amount.minor;
      if (minor > 0) {
        credits += minor;
      } else {
        debits -= minor;
      }
    }
    return ImportTotals(
      count: count,
      credits: Money(credits, currency),
      debits: Money(debits, currency),
    );
  }

  /// Totals of every valid row in the file.
  ImportTotals get totals => _totals(rows);

  /// Totals of rows that will create entries without a decision.
  ImportTotals get newTotals => _totals(
    rows.where(
      (r) => r.status == PreviewRowStatus.newEntry && !r.requiresDecision,
    ),
  );

  StatementCheck checkStatementBalance({
    required Money opening,
    required Money closing,
  }) => StatementCheck(expectedNet: closing - opening, importedNet: totals.net);
}

final _transferWords = RegExp(
  r'\b(transfer|tfr|xfer|trf|internal|to savings|from savings|osko|payid|'
  r'between accounts)\b',
  caseSensitive: false,
);
final _repaymentWords = RegExp(
  r'\b(card payment|credit card|cc payment|card repayment|visa payment|'
  r'mastercard payment|amex payment|payment thank you|thank you payment|'
  r'bpay)\b',
  caseSensitive: false,
);
final _paymentWords = RegExp(
  r'\b(payment|repayment|thank you|bpay)\b',
  caseSensitive: false,
);

/// Builds the preview of an import before anything is committed (IMP 01,
/// IMP 02, IMP 03).
///
/// For each parsed row, in order: an existing record with the same
/// fingerprint makes it a duplicate; another occurrence of the same
/// fingerprint base, or a record without a reference on the same date with
/// the same amount, makes it ambiguous; an existing entry on the account
/// with the same amount within [dateWindowDays] (preferring entries
/// created from receipts) makes it an existing match; otherwise it is new.
/// Rows are also flagged as possible transfers (transfer wording, or an
/// entry on another account with the opposite amount nearby) or card
/// repayments (repayment wording, a credit to a card or loan, or a
/// counterpart on a card or loan). Gaps longer than [gapThresholdDays]
/// within the file, or since the last import for the account, are listed.
ImportPreview previewImport({
  required String accountId,
  required CsvParseResult parsed,
  required String sourceHash,
  required Chart chart,
  Iterable<ImportBatch> batches = const [],
  Iterable<SourceRecord> existingRecords = const [],
  Iterable<Journal> journals = const [],
  Set<String> receiptJournalIds = const {},
  int dateWindowDays = 3,
  int gapThresholdDays = 10,
}) {
  final records = existingRecords
      .where((r) => r.accountId == accountId && !r.rolledBack)
      .toList();
  ImportBatch? already;
  for (final batch in batches) {
    if (batch.sourceHash == sourceHash &&
        batch.accountId == accountId &&
        batch.status == ImportBatchStatus.committed) {
      already = batch;
    }
  }

  final byFingerprint = <String, SourceRecord>{};
  final byBase = <String, SourceRecord>{};
  final byDateAmount = <String, List<SourceRecord>>{};
  for (final record in records) {
    byFingerprint[record.fingerprint] = record;
    final hash = record.fingerprint.lastIndexOf('#');
    if (hash > 0) byBase[record.fingerprint.substring(0, hash)] = record;
    byDateAmount
        .putIfAbsent('${record.date}|${record.amount.minor}', () => [])
        .add(record);
  }
  final matchedJournalIds = {
    for (final r in records)
      if (r.journalId != null) r.journalId!,
  };

  final account = chart.account(accountId);
  final ownJournals = <int, List<Journal>>{};
  final counterparts = <int, List<(Journal, Account)>>{};
  for (final journal in journals) {
    if (journal.status == JournalStatus.draft ||
        journal.status == JournalStatus.reversed ||
        journal.type == TransactionType.reversal) {
      continue;
    }
    final own = journal.amountFor(accountId);
    if (own != null) {
      ownJournals.putIfAbsent(own.minor, () => []).add(journal);
      continue;
    }
    for (final other in chart.accounts) {
      if (other.id == accountId) continue;
      final delta = journal.amountFor(other.id);
      if (delta != null) {
        counterparts.putIfAbsent(delta.minor, () => []).add((journal, other));
      }
    }
  }

  final fingerprints = assignFingerprints(accountId, parsed.rows);
  final rows = <PreviewRow>[];
  for (var i = 0; i < parsed.rows.length; i++) {
    final row = parsed.rows[i];
    final fingerprint = fingerprints[i];
    final exact = byFingerprint[fingerprint];
    if (already != null || exact != null) {
      rows.add(
        PreviewRow(
          row: row,
          fingerprint: fingerprint,
          status: PreviewRowStatus.duplicate,
          duplicateOf: exact,
        ),
      );
      continue;
    }
    final base = fingerprint.substring(0, fingerprint.lastIndexOf('#'));
    SourceRecord? similar = byBase[base];
    if (similar == null && row.reference == null) {
      similar = byDateAmount['${row.date}|${row.amount.minor}']
          ?.where((r) => r.reference == null)
          .firstOrNull;
    }
    final flags = <PreviewFlag>{};
    Journal? counterpart;
    final mirror = counterparts[-row.amount.minor] ?? const [];
    for (final (journal, other) in mirror) {
      if (row.date.daysUntil(journal.effectiveDate).abs() <= dateWindowDays) {
        counterpart = journal;
        flags.add(
          account.type.isLiability || other.type.isLiability
              ? PreviewFlag.possibleCardRepayment
              : PreviewFlag.possibleTransfer,
        );
        break;
      }
    }
    if (_repaymentWords.hasMatch(row.description) ||
        (account.type.isLiability &&
            row.amount.isPositive &&
            _paymentWords.hasMatch(row.description))) {
      flags.add(PreviewFlag.possibleCardRepayment);
    } else if (_transferWords.hasMatch(row.description)) {
      flags.add(PreviewFlag.possibleTransfer);
    }
    if (similar != null) {
      rows.add(
        PreviewRow(
          row: row,
          fingerprint: fingerprint,
          status: PreviewRowStatus.ambiguous,
          duplicateOf: similar,
          flags: flags,
          transferCounterpart: counterpart,
        ),
      );
      continue;
    }
    final proposals = proposeSourceMatches(
      row,
      accountId: accountId,
      journals: ownJournals[row.amount.minor] ?? const [],
      receiptJournalIds: receiptJournalIds,
      alreadyMatchedJournalIds: matchedJournalIds,
      dateWindowDays: dateWindowDays,
    );
    if (proposals.any((p) => p.receiptCreated)) {
      flags.add(PreviewFlag.receiptEntry);
    }
    rows.add(
      PreviewRow(
        row: row,
        fingerprint: fingerprint,
        status: proposals.isEmpty
            ? PreviewRowStatus.newEntry
            : PreviewRowStatus.existingMatch,
        flags: flags,
        proposals: proposals,
        transferCounterpart: counterpart,
      ),
    );
  }

  return ImportPreview(
    accountId: accountId,
    sourceHash: sourceHash,
    currency: chart.currency,
    rows: rows,
    errors: parsed.errors,
    dateGaps: _gaps(parsed.rows, records, gapThresholdDays),
    alreadyImportedBatch: already,
  );
}

List<DateGap> _gaps(
  List<ImportRow> rows,
  List<SourceRecord> records,
  int threshold,
) {
  if (rows.isEmpty) return const [];
  final dates = {for (final r in rows) r.date}.toList()..sort();
  final gaps = <DateGap>[];
  LocalDate? previous;
  for (final record in records) {
    if (record.date < dates.first &&
        (previous == null || record.date > previous)) {
      previous = record.date;
    }
  }
  if (previous != null && previous.daysUntil(dates.first) > threshold) {
    gaps.add(DateGap(previous, dates.first));
  }
  for (var i = 1; i < dates.length; i++) {
    if (dates[i - 1].daysUntil(dates[i]) > threshold) {
      gaps.add(DateGap(dates[i - 1], dates[i]));
    }
  }
  return gaps;
}
