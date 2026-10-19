import 'package:meta/meta.dart';

import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'payments.dart';
import 'reservations.dart';
import 'scenario.dart';
import 'schedules.dart';

/// How certain a forecast line is (PLAN 03); shown and exported separately.
enum ForecastCertainty {
  /// Recorded in the ledger: posted or pending journals.
  actual,

  /// Confirmed schedules and confirmed reservations.
  committed,

  /// Produced or changed by a scenario.
  hypothetical,
}

/// Where a forecast line came from.
enum ForecastSource { posted, pending, reservation, schedule, scenario }

/// Whether an account's money counts in cash forecasts: liquid, not
/// archived and included in forecasts. Credit limits, property and
/// superannuation never count.
bool isForecastEligible(Account account) =>
    account.includeInForecast && account.type.isLiquid && !account.archived;

/// One signed cash movement on one eligible account.
@immutable
class ForecastLine {
  const ForecastLine({
    required this.date,
    required this.accountId,
    required this.amount,
    required this.certainty,
    required this.source,
    required this.sourceId,
    this.description,
  });

  final LocalDate date;
  final String accountId;

  /// Positive adds cash, negative removes it.
  final Money amount;
  final ForecastCertainty certainty;
  final ForecastSource source;

  /// Journal id, occurrence key (`scheduleId@originalDate`), reservation id
  /// or scenario change id.
  final String sourceId;
  final String? description;
}

/// One projected day: opening and closing totals across eligible accounts.
@immutable
class ForecastDay {
  ForecastDay({
    required this.date,
    required this.opening,
    required List<ForecastLine> lines,
  }) : lines = List.unmodifiable(lines),
       closing = lines.fold(opening, (sum, l) => sum + l.amount);

  final LocalDate date;
  final Money opening;
  final List<ForecastLine> lines;
  final Money closing;
}

/// A day-by-day cash projection from [start] to [end] inclusive.
@immutable
class CashForecast {
  CashForecast({
    required this.start,
    required this.end,
    required Set<String> accountIds,
    required this.openingBalance,
    required List<ForecastDay> days,
  }) : accountIds = Set.unmodifiable(accountIds),
       days = List.unmodifiable(days),
       _lowest = _lowestDay(days);

  static ForecastDay _lowestDay(List<ForecastDay> days) {
    var lowest = days.first;
    for (final day in days) {
      if (day.closing < lowest.closing) lowest = day;
    }
    return lowest;
  }

  final LocalDate start;
  final LocalDate end;

  /// Eligible cash accounts included in the projection.
  final Set<String> accountIds;

  /// Posted balance of eligible accounts at the end of [start].
  final Money openingBalance;
  final List<ForecastDay> days;

  final ForecastDay _lowest;

  /// The lowest closing balance over the horizon.
  Money get lowestBalance => _lowest.closing;

  /// The earliest date on which [lowestBalance] occurs.
  LocalDate get lowestDate => _lowest.date;

  List<ForecastLine> get lines => [for (final d in days) ...d.lines];

  bool get includesHypothetical => days.any(
    (d) => d.lines.any((l) => l.certainty == ForecastCertainty.hypothetical),
  );

  ForecastDay? day(LocalDate date) {
    final index = start.daysUntil(date);
    return index < 0 || index >= days.length ? null : days[index];
  }
}

/// Projects eligible cash day by day (PLAN 03).
///
/// * Opening: posted balances of eligible accounts on [today], including
///   journals dated today.
/// * Actual lines: posted journals dated after today, and pending journals
///   (on their date, or today if earlier).
/// * Committed lines: confirmed reservations in eligible accounts (today),
///   and the outstanding amount of each confirmed schedule occurrence due
///   from `today − overdueLookbackDays` to the end (overdue ones today).
///   Occurrences linked to posted or pending journals are consumed, so a
///   paid bill is never counted twice (A13). Transfers affect each eligible
///   side; unconfirmed income is left out.
/// * Hypothetical lines: whatever [scenario] adds or changes.
///
/// The horizon is [horizonDays] days starting today, or ends on [end].
CashForecast buildCashForecast({
  required LedgerProjection ledger,
  required LocalDate today,
  int horizonDays = 90,
  LocalDate? end,
  Iterable<RecurringSchedule> schedules = const [],
  Iterable<OccurrenceOverride> overrides = const [],
  Iterable<OccurrencePayment> payments = const [],
  Iterable<Reservation> reservations = const [],
  Scenario? scenario,
  int overdueLookbackDays = 0,
}) {
  final chart = ledger.chart;
  final currency = chart.currency;
  final last = end ?? today.addDays(horizonDays - 1);
  if (last < today) throw ArgumentError('The horizon ends before today');
  final eligible = {
    for (final a in chart.accounts)
      if (isForecastEligible(a)) a.id,
  };
  final lines = <ForecastLine>[];
  LocalDate notBeforeToday(LocalDate date) => date < today ? today : date;

  var opening = 0;
  final statuses = <String, JournalStatus>{};
  for (final journal in ledger.journals) {
    statuses[journal.id] = journal.status;
    final posted = journal.status.inPostedLedger;
    if (!posted && journal.status != JournalStatus.pending) continue;
    final date = journal.effectiveDate;
    if (posted && date <= today) {
      for (final p in journal.postings) {
        if (eligible.contains(p.ledgerAccountId)) opening += p.amount.minor;
      }
      continue;
    }
    if (date > last) continue;
    final byAccount = <String, int>{};
    for (final p in journal.postings) {
      if (eligible.contains(p.ledgerAccountId)) {
        byAccount[p.ledgerAccountId] =
            (byAccount[p.ledgerAccountId] ?? 0) + p.amount.minor;
      }
    }
    byAccount.forEach((account, minor) {
      lines.add(
        ForecastLine(
          date: notBeforeToday(date),
          accountId: account,
          amount: Money(minor, currency),
          certainty: ForecastCertainty.actual,
          source: posted ? ForecastSource.posted : ForecastSource.pending,
          sourceId: journal.id,
          description: journal.payee,
        ),
      );
    });
  }

  for (final r in reservations) {
    if (!r.confirmed || !eligible.contains(r.accountId)) continue;
    lines.add(
      ForecastLine(
        date: today,
        accountId: r.accountId,
        amount: -r.amount,
        certainty: ForecastCertainty.committed,
        source: ForecastSource.reservation,
        sourceId: r.id,
      ),
    );
  }

  final changes = scenario?.changes ?? const <ScenarioChange>[];
  final removed = {
    for (final c in changes.whereType<RemoveScheduleChange>()) c.scheduleId,
  };
  final amounts = {
    for (final c in changes.whereType<ScheduleAmountChange>())
      c.scheduleId: c.amount,
  };
  final projected = [
    for (final s in schedules)
      if (!removed.contains(s.id)) (s, amounts.containsKey(s.id)),
    for (final c in changes.whereType<AddScheduleChange>()) (c.schedule, true),
  ];
  final paymentList = payments.toList();
  for (final (schedule, hypothetical) in projected) {
    if (!schedule.confirmed) continue;
    final effective = amounts.containsKey(schedule.id)
        ? schedule.copyWith(amount: amounts[schedule.id])
        : schedule;
    final occurrences = effective.occurrencesBetween(
      today.addDays(-overdueLookbackDays),
      last,
      overrides: overrides,
    );
    for (final occurrence in occurrences) {
      if (occurrence.skipped) continue;
      final outstanding = assessOccurrence(
        occurrence,
        payments: paymentList,
        journalStatuses: statuses,
        today: today,
      ).outstanding;
      if (outstanding.isZero) continue;
      for (final (account, amount) in cashEffects(effective, outstanding)) {
        if (!eligible.contains(account)) continue;
        lines.add(
          ForecastLine(
            date: notBeforeToday(occurrence.dueDate),
            accountId: account,
            amount: amount,
            certainty: hypothetical
                ? ForecastCertainty.hypothetical
                : ForecastCertainty.committed,
            source: ForecastSource.schedule,
            sourceId: occurrence.key,
            description: schedule.name,
          ),
        );
      }
    }
  }

  for (final c in changes.whereType<OneOffChange>()) {
    if (!eligible.contains(c.accountId) || c.date < today || c.date > last) {
      continue;
    }
    lines.add(
      ForecastLine(
        date: c.date,
        accountId: c.accountId,
        amount: c.amount,
        certainty: ForecastCertainty.hypothetical,
        source: ForecastSource.scenario,
        sourceId: c.id,
        description: c.description,
      ),
    );
  }

  final byDay = <LocalDate, List<ForecastLine>>{};
  for (final line in lines) {
    byDay.putIfAbsent(line.date, () => []).add(line);
  }
  final days = <ForecastDay>[];
  var balance = Money(opening, currency);
  for (var date = today; date <= last; date = date.addDays(1)) {
    final day = ForecastDay(
      date: date,
      opening: balance,
      lines: byDay[date] ?? const [],
    );
    days.add(day);
    balance = day.closing;
  }
  return CashForecast(
    start: today,
    end: last,
    accountIds: eligible,
    openingBalance: Money(opening, currency),
    days: days,
  );
}

/// Signed cash effect of one occurrence of [schedule] per account: bills
/// and transfers leave the paying account, income and transfers arrive in
/// the receiving account.
List<(String, Money)> cashEffects(RecurringSchedule schedule, Money amount) =>
    switch (schedule.kind) {
      ScheduleKind.expense => [(schedule.accountId, -amount)],
      ScheduleKind.income => [(schedule.accountId, amount)],
      ScheduleKind.transfer => [
        (schedule.accountId, -amount),
        (schedule.counterAccountId!, amount),
      ],
    };
