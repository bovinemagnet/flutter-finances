import 'package:meta/meta.dart';

import '../documents/text/normalise.dart';
import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'date_range.dart';
import 'ledger_reports.dart';
import 'recurrence.dart';
import 'schedules.dart';

/// How strongly the evidence supports a detection. A heuristic category,
/// never a probability.
enum DetectionConfidence { high, medium, low }

/// The evidence behind a subscription proposal.
enum SubscriptionReason {
  /// Every payment went to the same merchant (after normalisation).
  sameMerchant('SAME_MERCHANT'),

  /// Every payment had exactly the same amount.
  identicalAmount('IDENTICAL_AMOUNT'),

  /// The amounts differ, but by no more than the tolerance.
  similarAmount('SIMILAR_AMOUNT'),

  /// Every interval between payments fits the frequency.
  regularInterval('REGULAR_INTERVAL'),

  /// All but one interval fit the frequency (for example a skipped month).
  oneIrregularInterval('ONE_IRREGULAR_INTERVAL');

  const SubscriptionReason(this.code);
  final String code;
}

/// A merchant that appears to charge regularly (REP 03, P1). It proposes a
/// schedule; nothing is saved until the user confirms it.
@immutable
class SubscriptionProposal {
  SubscriptionProposal({
    required this.merchantKey,
    required this.payee,
    required this.accountId,
    required this.categoryId,
    required this.frequency,
    required this.amount,
    required this.amountVaries,
    required this.firstDate,
    required this.lastDate,
    required this.nextDueDate,
    required List<String> journalIds,
    required this.confidence,
    required Set<SubscriptionReason> reasons,
  }) : journalIds = List.unmodifiable(journalIds),
       reasons = Set.unmodifiable(reasons);

  /// The normalised merchant name the payments share.
  final String merchantKey;

  /// The payee as written on the latest payment.
  final String payee;

  /// Account and category of the latest payment.
  final String accountId;
  final String? categoryId;
  final Frequency frequency;

  /// The latest payment's amount.
  final Money amount;

  /// True when the payments were similar rather than identical.
  final bool amountVaries;
  final LocalDate firstDate;
  final LocalDate lastDate;

  /// The first expected payment on or after the detection date.
  final LocalDate nextDueDate;

  /// The payments that form the pattern, in date order.
  final List<String> journalIds;
  final DetectionConfidence confidence;
  final Set<SubscriptionReason> reasons;

  /// Stable identity for the insight and its dismiss or snooze state.
  String get key =>
      'possibleSubscription:$merchantKey:${frequency.name}:${amount.minor}';

  /// The schedule the user can confirm. It is unconfirmed, so it affects
  /// no forecast or estimate until the user accepts it (saving it with
  /// `confirmed: true`).
  RecurringSchedule toSchedule({required String id, String? name}) =>
      RecurringSchedule(
        id: id,
        name: name ?? payee,
        kind: ScheduleKind.expense,
        recurrence: Recurrence(
          frequency: frequency,
          start: nextDueDate,
          // Keeps the 31st after a clamped February due date.
          dayOfMonth: frequency.isMonthBased ? lastDate.day : null,
        ),
        amount: amount,
        isEstimate: amountVaries,
        accountId: accountId,
        categoryId: categoryId,
        payee: payee,
        confirmed: false,
      );
}

/// Interval rules: the accepted gap in days between payments and the
/// nominal gap used to decide whether a series has stopped.
const _cadences = [
  (frequency: Frequency.weekly, min: 6, max: 8, nominal: 7),
  (frequency: Frequency.fortnightly, min: 12, max: 16, nominal: 14),
  (frequency: Frequency.monthly, min: 26, max: 35, nominal: 30),
  (frequency: Frequency.quarterly, min: 84, max: 98, nominal: 91),
  (frequency: Frequency.annually, min: 358, max: 372, nominal: 365),
];

LocalDate _advance(LocalDate date, Frequency frequency, int intendedDay) =>
    frequency.isMonthBased
    ? date.addMonths(frequency.months, intendedDay: intendedDay)
    : date.addDays(frequency.days);

/// Finds merchants that charge regularly (subscription detection, P1).
///
/// Posted expenses with a payee from the [lookbackDays] before [today] are
/// grouped by [normaliseMerchant] of the payee, then into amount clusters:
/// sorted by amount, a payment joins the cluster when it is at most
/// [amountToleranceBasisPoints] above the cluster's smallest amount. A
/// cluster with at least [minOccurrences] payments is proposed when:
///
/// - the median gap between consecutive payment dates falls in a cadence:
///   weekly 6–8 days, fortnightly 12–16, monthly 26–35, quarterly 84–98 or
///   annually 358–372;
/// - every gap fits that cadence, or all but one when there are at least
///   three gaps;
/// - the series is still active: the last payment is no more than twice
///   the nominal gap (7, 14, 30, 91 or 365 days) plus the cadence's
///   tolerance before [today];
/// - no [existingSchedules] entry has the same normalised payee or name.
///
/// Confidence is high when every gap fits, every amount is identical and
/// there are at least four payments; medium when every gap fits; low when
/// one gap does not. The next due date steps from the last payment
/// (keeping its day of month) until it is on or after [today].
///
/// Proposals are ordered by merchant key, then frequency and amount.
List<SubscriptionProposal> detectSubscriptions({
  required LedgerProjection ledger,
  required LocalDate today,
  Iterable<RecurringSchedule> existingSchedules = const [],
  int lookbackDays = 400,
  int minOccurrences = 3,
  int amountToleranceBasisPoints = 1000,
}) {
  final scheduled = {
    for (final s in existingSchedules) ...[
      normaliseMerchant(s.name),
      if (s.payee != null) normaliseMerchant(s.payee!),
    ],
  };
  final byMerchant = <String, List<Journal>>{};
  final window = DateRange(today.addDays(-lookbackDays), today);
  for (final journal in purchasesIn(ledger, window)) {
    final payee = journal.payee?.trim() ?? '';
    if (payee.isEmpty || journal.amount == null) continue;
    final key = normaliseMerchant(payee);
    if (key.isEmpty || scheduled.contains(key)) continue;
    byMerchant.putIfAbsent(key, () => []).add(journal);
  }

  final proposals = <SubscriptionProposal>[];
  for (final MapEntry(key: merchant, value: journals) in byMerchant.entries) {
    final byAmount = [...journals]
      ..sort((a, b) => a.amount!.minor.compareTo(b.amount!.minor));
    final clusters = <List<Journal>>[];
    for (final journal in byAmount) {
      final cluster = clusters.lastOrNull;
      if (cluster != null &&
          journal.amount!.minor * 10000 <=
              cluster.first.amount!.minor *
                  (10000 + amountToleranceBasisPoints)) {
        cluster.add(journal);
      } else {
        clusters.add([journal]);
      }
    }
    for (final cluster in clusters) {
      if (cluster.length < minOccurrences) continue;
      final proposal = _propose(ledger.chart, merchant, cluster, today);
      if (proposal != null) proposals.add(proposal);
    }
  }
  proposals.sort((a, b) {
    final byKey = a.merchantKey.compareTo(b.merchantKey);
    if (byKey != 0) return byKey;
    final byFrequency = a.frequency.index.compareTo(b.frequency.index);
    return byFrequency != 0
        ? byFrequency
        : a.amount.minor.compareTo(b.amount.minor);
  });
  return proposals;
}

SubscriptionProposal? _propose(
  Chart chart,
  String merchant,
  List<Journal> cluster,
  LocalDate today,
) {
  // purchasesIn returns date order; the amount sort is stable per amount,
  // so restore date order explicitly.
  final series = [...cluster]
    ..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
  final gaps = [
    for (var i = 1; i < series.length; i++)
      series[i - 1].effectiveDate.daysUntil(series[i].effectiveDate),
  ];
  final sortedGaps = [...gaps]..sort();
  final mid = sortedGaps.length ~/ 2;
  final medianTwice = sortedGaps.length.isOdd
      ? 2 * sortedGaps[mid]
      : sortedGaps[mid - 1] + sortedGaps[mid];
  final cadence = _cadences
      .where((c) => medianTwice >= 2 * c.min && medianTwice <= 2 * c.max)
      .firstOrNull;
  if (cadence == null) return null;
  final irregular = gaps
      .where((g) => g < cadence.min || g > cadence.max)
      .length;
  if (irregular > 1 || (irregular == 1 && gaps.length < 3)) return null;

  final last = series.last;
  final tolerance = cadence.max - cadence.nominal;
  if (last.effectiveDate.daysUntil(today) > 2 * cadence.nominal + tolerance) {
    return null;
  }
  final identical = series.every((j) => j.amount == last.amount);
  final frequency = cadence.frequency;
  final day = last.effectiveDate.day;
  var next = _advance(last.effectiveDate, frequency, day);
  while (next < today) {
    next = _advance(next, frequency, day);
  }
  String? category;
  for (final posting in last.postings) {
    if (chart.kindOf(posting.ledgerAccountId) == LedgerKind.expense) {
      category = posting.ledgerAccountId;
      break;
    }
  }
  return SubscriptionProposal(
    merchantKey: merchant,
    payee: last.payee!.trim(),
    accountId: last.accountId!,
    categoryId: category,
    frequency: frequency,
    amount: last.amount!,
    amountVaries: !identical,
    firstDate: series.first.effectiveDate,
    lastDate: last.effectiveDate,
    nextDueDate: next,
    journalIds: [for (final j in series) j.id],
    confidence: irregular > 0
        ? DetectionConfidence.low
        : identical && series.length >= 4
        ? DetectionConfidence.high
        : DetectionConfidence.medium,
    reasons: {
      SubscriptionReason.sameMerchant,
      identical
          ? SubscriptionReason.identicalAmount
          : SubscriptionReason.similarAmount,
      irregular > 0
          ? SubscriptionReason.oneIrregularInterval
          : SubscriptionReason.regularInterval,
    },
  );
}
