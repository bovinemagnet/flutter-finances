import 'package:meta/meta.dart';

import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'budget_evaluation.dart';
import 'date_range.dart';
import 'forecast.dart';
import 'ledger_reports.dart';

/// The initial explainable insight rules (REP 03).
enum InsightRule {
  overBudget,
  lowCash,
  unreviewed,
  missingReceipt,
  possibleDuplicate,
}

/// An explanation the user may act on. Insights only describe; they never
/// move money or change budgets, and acting on one goes through the normal
/// confirmed commands.
@immutable
class Insight {
  Insight({
    required this.key,
    required this.rule,
    required this.trigger,
    required List<String> entryIds,
    required this.period,
    this.amount,
  }) : entryIds = List.unmodifiable(entryIds);

  /// Stable identity used by [InsightState], for example
  /// `overBudget:dining:2026-07-01`.
  final String key;
  final InsightRule rule;

  /// Why the insight fired, in plain words.
  final String trigger;

  /// Underlying journal ids or forecast source ids.
  final List<String> entryIds;
  final DateRange period;

  /// Overspend, lowest projected balance or purchase amount, when relevant.
  final Money? amount;
}

/// The user's dismiss or snooze decision for one insight.
@immutable
class InsightState {
  const InsightState({
    required this.id,
    required this.insightKey,
    this.dismissed = false,
    this.snoozedUntil,
  });

  final String id;
  final String insightKey;
  final bool dismissed;

  /// Hidden before this date; shown again from it.
  final LocalDate? snoozedUntil;
}

/// Whether a rule is enabled, and its threshold where one applies (the
/// missing-receipt amount or the low-cash balance).
@immutable
class InsightRuleSetting {
  const InsightRuleSetting({
    required this.id,
    required this.rule,
    this.enabled = true,
    this.threshold,
  });

  final String id;
  final InsightRule rule;
  final bool enabled;
  final Money? threshold;
}

/// Evaluates every rule whose inputs are supplied, ordered by rule then
/// input order:
///
/// * over budget: [budget] lines (including unbudgeted spending) whose
///   remaining is below zero;
/// * low cash: [forecast] lowest balance below [lowCashThreshold] (zero by
///   default); entries are outflow sources up to the lowest day;
/// * unreviewed: [unreviewedJournalIds], one insight for [period];
/// * missing receipt: posted purchases in [period] of at least
///   [missingReceiptThreshold] without a receipt;
/// * possible duplicates: caller-supplied candidate pairs.
List<Insight> generateInsights({
  required DateRange period,
  BudgetPeriodEvaluation? budget,
  CashForecast? forecast,
  Money? lowCashThreshold,
  LedgerProjection? ledger,
  Set<String> unreviewedJournalIds = const {},
  Set<String> receiptJournalIds = const {},
  Money? missingReceiptThreshold,
  List<(String, String)> duplicateCandidates = const [],
}) {
  final insights = <Insight>[];
  if (budget != null) {
    final budgetPeriod = DateRange(budget.period.start, budget.period.end);
    for (final line in [...budget.lines, ...budget.unbudgeted]) {
      if (!line.remaining.isNegative) continue;
      final over = -line.remaining;
      insights.add(
        Insight(
          key: 'overBudget:${line.targetId}:${budget.period.start}',
          rule: InsightRule.overBudget,
          trigger:
              '${line.targetId} is over budget by ${over.toDecimalString()}',
          entryIds: line.journalIds,
          period: budgetPeriod,
          amount: over,
        ),
      );
    }
  }
  if (forecast != null) {
    final threshold =
        lowCashThreshold ?? Money.zero(forecast.openingBalance.currency);
    if (forecast.lowestBalance < threshold) {
      insights.add(
        Insight(
          key: 'lowCash:${forecast.lowestDate}',
          rule: InsightRule.lowCash,
          trigger:
              'Projected cash falls to '
              '${forecast.lowestBalance.toDecimalString()} on '
              '${forecast.lowestDate}',
          entryIds: [
            for (final day in forecast.days)
              if (day.date <= forecast.lowestDate)
                for (final line in day.lines)
                  if (line.amount.isNegative) line.sourceId,
          ],
          period: DateRange(forecast.start, forecast.end),
          amount: forecast.lowestBalance,
        ),
      );
    }
  }
  if (unreviewedJournalIds.isNotEmpty) {
    insights.add(
      Insight(
        key: 'unreviewed:$period',
        rule: InsightRule.unreviewed,
        trigger: '${unreviewedJournalIds.length} transactions need review',
        entryIds: unreviewedJournalIds.toList()..sort(),
        period: period,
      ),
    );
  }
  if (ledger != null && missingReceiptThreshold != null) {
    for (final journal in purchasesIn(ledger, period)) {
      final amount = journal.amount;
      if (amount == null ||
          amount < missingReceiptThreshold ||
          receiptJournalIds.contains(journal.id)) {
        continue;
      }
      insights.add(
        Insight(
          key: 'missingReceipt:${journal.id}',
          rule: InsightRule.missingReceipt,
          trigger: 'A purchase of ${amount.toDecimalString()} has no receipt',
          entryIds: [journal.id],
          period: period,
          amount: amount,
        ),
      );
    }
  }
  for (final (a, b) in duplicateCandidates) {
    final pair = [a, b]..sort();
    insights.add(
      Insight(
        key: 'possibleDuplicate:${pair.join('|')}',
        rule: InsightRule.possibleDuplicate,
        trigger: 'These entries may be duplicates',
        entryIds: pair,
        period: period,
      ),
    );
  }
  return insights;
}

/// Insights to show on [today]: not dismissed, not snoozed until after
/// today, and from an enabled rule.
List<Insight> visibleInsights(
  List<Insight> insights, {
  required LocalDate today,
  Iterable<InsightState> states = const [],
  Iterable<InsightRuleSetting> settings = const [],
}) {
  final byKey = {for (final s in states) s.insightKey: s};
  final disabled = {
    for (final s in settings)
      if (!s.enabled) s.rule,
  };
  return [
    for (final insight in insights)
      if (!disabled.contains(insight.rule) &&
          !_hidden(byKey[insight.key], today))
        insight,
  ];
}

bool _hidden(InsightState? state, LocalDate today) {
  if (state == null) return false;
  final until = state.snoozedUntil;
  return state.dismissed || (until != null && today < until);
}
