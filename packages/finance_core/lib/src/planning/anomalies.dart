import 'package:meta/meta.dart';

import '../documents/text/normalise.dart';
import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'category_activity.dart';
import 'date_range.dart';
import 'ledger_reports.dart';
import 'robust_stats.dart';

/// What an unusual purchase was compared with.
enum AnomalyBasis {
  /// Earlier purchases from the same merchant.
  merchant,

  /// Earlier purchases in the same category.
  category,
}

/// A purchase well above what is usual for its merchant or category
/// (REP 03, P1). It only explains; it never changes anything.
@immutable
class UnusualTransaction {
  UnusualTransaction({
    required this.journalId,
    required this.date,
    required this.amount,
    required this.basis,
    required this.basisKey,
    required this.basisLabel,
    required this.median,
    required this.deviation,
    required List<String> historyJournalIds,
  }) : historyJournalIds = List.unmodifiable(historyJournalIds);

  final String journalId;
  final LocalDate date;
  final Money amount;
  final AnomalyBasis basis;

  /// The normalised merchant name or the category id.
  final String basisKey;

  /// The payee as written, or the category name.
  final String basisLabel;

  /// Median of the earlier purchases, rounded half away from zero.
  final Money median;

  /// Median absolute deviation of the earlier purchases, before the floor
  /// described on [detectUnusualTransactions], rounded half away from zero.
  final Money deviation;

  /// The earlier purchases compared with, in date order.
  final List<String> historyJournalIds;

  String get key => 'unusualTransaction:$journalId';
}

/// One category's spending in a month far above its recent months.
@immutable
class SpendingSpike {
  SpendingSpike({
    required this.categoryId,
    required this.categoryName,
    required this.month,
    required this.spending,
    required this.median,
    required this.historyMonths,
    required this.firstSpending,
    required List<String> journalIds,
  }) : journalIds = List.unmodifiable(journalIds);

  final String categoryId;
  final String categoryName;

  /// The calendar month with the spike.
  final DateRange month;

  /// Net spending in [month] (refunds reduce it).
  final Money spending;

  /// Median monthly spending over the history months.
  final Money median;
  final int historyMonths;

  /// True when the category had no spending in any history month.
  final bool firstSpending;

  /// The entries behind [spending].
  final List<String> journalIds;

  String get key => 'spendingSpike:$categoryId:${month.start}';
}

/// The expense category with the largest posting in [journal].
String? _mainCategory(Chart chart, Journal journal) {
  String? best;
  var largest = 0;
  for (final p in journal.postings) {
    if (chart.kindOf(p.ledgerAccountId) == LedgerKind.expense &&
        p.amount.minor > largest) {
      largest = p.amount.minor;
      best = p.ledgerAccountId;
    }
  }
  return best;
}

/// Finds posted purchases in [period] that are unusually large (anomaly
/// detection, P1).
///
/// Each purchase is compared with posted purchases dated before it within
/// [lookbackDays]: those from the same merchant ([normaliseMerchant] of
/// the payee) when there are at least [minHistory], otherwise those whose
/// main expense category (largest expense posting) is the same, when there
/// are at least [minHistory]; otherwise it is not judged. It is unusual
/// when its modified z-score exceeds 3.5:
/// `6745 × (amount − median) > 35000 × MAD` in exact integer arithmetic,
/// where MAD (median absolute deviation) is raised to at least a tenth of
/// the median and one minor unit, and the amount exceeds the median by at
/// least [minimumExcess]. Results are in date order.
List<UnusualTransaction> detectUnusualTransactions({
  required LedgerProjection ledger,
  required DateRange period,
  int lookbackDays = 365,
  int minHistory = 5,
  Money? minimumExcess,
}) {
  final chart = ledger.chart;
  final all = purchasesIn(
    ledger,
    DateRange(period.start.addDays(-lookbackDays), period.end),
  ).where((j) => j.amount != null).toList();
  String? merchantOf(Journal j) {
    final payee = j.payee?.trim() ?? '';
    return payee.isEmpty ? null : normaliseMerchant(payee);
  }

  final found = <UnusualTransaction>[];
  for (final journal in all) {
    if (!period.contains(journal.effectiveDate)) continue;
    final earliest = journal.effectiveDate.addDays(-lookbackDays);
    final earlier = [
      for (final j in all)
        if (j.effectiveDate < journal.effectiveDate &&
            j.effectiveDate >= earliest)
          j,
    ];
    final merchant = merchantOf(journal);
    final category = _mainCategory(chart, journal);
    var basis = AnomalyBasis.merchant;
    var history = merchant == null
        ? const <Journal>[]
        : [
            for (final j in earlier)
              if (merchantOf(j) == merchant) j,
          ];
    if (history.length < minHistory) {
      basis = AnomalyBasis.category;
      history = category == null
          ? const []
          : [
              for (final j in earlier)
                if (_mainCategory(chart, j) == category) j,
            ];
    }
    if (history.length < minHistory) continue;
    final values = [for (final j in history) j.amount!.minor];
    if (!isUnusuallyHigh(
      journal.amount!.minor,
      values,
      minimumExcess: minimumExcess?.minor ?? 0,
    )) {
      continue;
    }
    final (:median4, :mad4) = medianAndMad(values);
    found.add(
      UnusualTransaction(
        journalId: journal.id,
        date: journal.effectiveDate,
        amount: journal.amount!,
        basis: basis,
        basisKey: basis == AnomalyBasis.merchant ? merchant! : category!,
        basisLabel: basis == AnomalyBasis.merchant
            ? journal.payee!.trim()
            : chart.category(category!).name,
        median: Money(divideRounded(median4, 4), chart.currency),
        deviation: Money(divideRounded(mad4, 4), chart.currency),
        historyJournalIds: [for (final j in history) j.id],
      ),
    );
  }
  return found;
}

LocalDate _monthStart(LocalDate date) => LocalDate(date.year, date.month, 1);

/// Finds expense categories whose spending in the calendar month containing
/// [month] is far above their recent months (anomaly detection, P1).
///
/// History is the [historyMonths] calendar months before it, limited to
/// months from the one holding the earliest posted entry, so a new ledger
/// is not compared with empty months; with fewer than [minHistoryMonths]
/// nothing is reported. Each category with positive net spending in the
/// month is compared with its monthly net spending using the same rule as
/// [detectUnusualTransactions] (a category with no history spending has a
/// median of zero and is marked [SpendingSpike.firstSpending]). Results are
/// ordered by spending, largest first, then category id.
List<SpendingSpike> detectSpendingSpikes({
  required LedgerProjection ledger,
  required LocalDate month,
  int historyMonths = 6,
  int minHistoryMonths = 3,
  Money? minimumExcess,
}) {
  final chart = ledger.chart;
  LocalDate? earliest;
  for (final journal in ledger.journals) {
    if (!journal.status.inPostedLedger) continue;
    if (earliest == null || journal.effectiveDate < earliest) {
      earliest = journal.effectiveDate;
    }
  }
  if (earliest == null) return const [];
  final start = _monthStart(month);
  final current = DateRange(start, start.addMonths(1).addDays(-1));
  final firstAllowed = _monthStart(earliest);
  final history = [
    for (var i = historyMonths; i >= 1; i--)
      if (start.addMonths(-i) >= firstAllowed)
        DateRange(start.addMonths(-i), start.addMonths(-i + 1).addDays(-1)),
  ];
  if (history.length < minHistoryMonths) return const [];

  final index = CategoryActivityIndex.fromLedger(ledger);
  final spikes = <SpendingSpike>[];
  for (final id in index.activeCategories(current.start, current.end)) {
    final category = chart.category(id);
    if (category.kind != CategoryKind.expense) continue;
    final spending = index.net(id, current.start, current.end);
    if (!spending.isPositive) continue;
    final values = [
      for (final range in history) index.net(id, range.start, range.end).minor,
    ];
    if (!isUnusuallyHigh(
      spending.minor,
      values,
      minimumExcess: minimumExcess?.minor ?? 0,
    )) {
      continue;
    }
    final (:median4, mad4: _) = medianAndMad(values);
    spikes.add(
      SpendingSpike(
        categoryId: id,
        categoryName: category.name,
        month: current,
        spending: spending,
        median: Money(divideRounded(median4, 4), chart.currency),
        historyMonths: history.length,
        firstSpending: values.every((v) => v <= 0),
        journalIds: index.journalIds(id, current.start, current.end),
      ),
    );
  }
  spikes.sort((a, b) {
    final bySpending = b.spending.minor.compareTo(a.spending.minor);
    return bySpending != 0 ? bySpending : a.categoryId.compareTo(b.categoryId);
  });
  return spikes;
}
