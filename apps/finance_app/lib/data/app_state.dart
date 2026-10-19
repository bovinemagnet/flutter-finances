import 'package:finance_core/finance_core.dart';
import 'package:finance_core/finance_core.dart'
    as core
    show goalProgress, linkPayment;
import 'package:finance_store/finance_store.dart';
import 'package:flutter/foundation.dart';

import '../features/accounts/account_editor.dart';
import '../features/onboarding/onboarding_model.dart';
import '../features/transactions/transaction_form_model.dart';
import 'entity_types.dart';
import 'receipt_service.dart';

/// Application state over the encrypted local store.
///
/// Every write goes through [FinanceStore], which saves the change and its
/// outbox command in one transaction; this class then drops its derived
/// caches and notifies listeners. Figures are always recomputed from
/// journals and persisted plans, never stored as editable balances.
class AppState extends ChangeNotifier {
  AppState(this.store, {required this.today});

  final FinanceStore store;
  final LocalDate Function() today;

  /// Receipt capture, extraction and review over the same store.
  late final ReceiptService receipts = ReceiptService(this);

  Currency get currency => store.settings.currency;
  WorkspaceSettings get settings => store.settings;

  Chart? _chart;
  LedgerProjection? _ledger;

  Chart get chart => _chart ??= Chart(
    currency: currency,
    accounts: store.accounts(),
    categories: store.categories(),
  );

  LedgerProjection get ledger => _ledger ??= store.projection();

  int get unsyncedCount => store.pendingCommandCount;
  bool isUnsynced(String type, String id) => store.isUnsynced(type, id);

  /// Call after anything outside this class changed the store, such as a
  /// sync pull.
  void refresh() {
    _chart = null;
    _ledger = null;
    notifyListeners();
  }

  // Generic entities ------------------------------------------------------

  List<T> _all<T>(String type, T Function(Map<String, Object?> json) decode) =>
      [
        for (final record in store.entities(type))
          if (!record.deleted) decode(record.json),
      ];

  Future<void> _put(String type, String id, Map<String, Object?> json) async {
    await store.upsertEntity(type, id, json);
  }

  BudgetPlan? get budgetPlan {
    final plans = _all(
      AppEntityTypes.budgetPlan,
      (j) => budgetPlanFromJson(j, currency),
    );
    return plans.isEmpty ? null : plans.first;
  }

  List<BudgetAdjustment> get adjustments => _all(
    AppEntityTypes.budgetAdjustment,
    (j) => budgetAdjustmentFromJson(j, currency),
  );
  List<RecurringSchedule> get schedules => _all(
    AppEntityTypes.recurringSchedule,
    (j) => recurringScheduleFromJson(j, currency),
  );
  List<OccurrenceOverride> get overrides => _all(
    AppEntityTypes.occurrenceOverride,
    (j) => occurrenceOverrideFromJson(j, currency),
  );
  List<OccurrencePayment> get payments => _all(
    AppEntityTypes.occurrencePayment,
    (j) => occurrencePaymentFromJson(j, currency),
  );
  List<Goal> get goals =>
      _all(AppEntityTypes.goal, (j) => goalFromJson(j, currency));
  List<SavingsAllocation> get savingsAllocations => _all(
    AppEntityTypes.savingsAllocation,
    (j) => savingsAllocationFromJson(j, currency),
  );
  List<Reservation> get reservations =>
      _all(AppEntityTypes.reservation, (j) => reservationFromJson(j, currency));
  List<InsightState> get insightStates =>
      _all(AppEntityTypes.insightState, insightStateFromJson);
  List<InsightRuleSetting> get ruleSettings => _all(
    AppEntityTypes.insightRuleSetting,
    (j) => insightRuleSettingFromJson(j, currency),
  );

  Set<String> get reviewedJournalIds => {
    for (final record in store.entities(AppEntityTypes.transactionReview))
      if (!record.deleted && record.json['reviewed'] == true) record.ref.id,
  };

  /// Posted and pending entries the user has not reviewed yet (Journey C).
  Set<String> get unreviewedJournalIds {
    final reviewed = reviewedJournalIds;
    return {
      for (final j in ledger.journals)
        if ((j.status == JournalStatus.posted ||
                j.status == JournalStatus.pending) &&
            j.type != TransactionType.reversal &&
            j.type != TransactionType.openingBalance &&
            !reviewed.contains(j.id))
          j.id,
    };
  }

  // Transactions ----------------------------------------------------------

  Future<Journal> post(TransactionDraft draft) async {
    final journal = await store.postTransaction(draft);
    refresh();
    return journal;
  }

  /// An ordinary edit; posted entries become a reversal plus replacement.
  Future<CorrectionResult?> correct(
    String journalId,
    TransactionDraft? draft,
  ) async {
    final existing = store.journal(journalId);
    if (existing == null) return null;
    if (!existing.status.inPostedLedger) {
      if (draft == null) {
        await store.deleteDraft(journalId);
      } else {
        await store.postTransaction(
          TransactionDraft(
            id: journalId,
            type: draft.type,
            accountId: draft.accountId,
            counterAccountId: draft.counterAccountId,
            amount: draft.amount,
            effectiveDate: draft.effectiveDate,
            splits: draft.splits,
            status: draft.status,
            payee: draft.payee,
            notes: draft.notes,
            tags: draft.tags,
            refundOf: draft.refundOf,
          ),
        );
      }
      refresh();
      return null;
    }
    final result = await store.correctTransaction(journalId, draft);
    if (reviewedJournalIds.contains(journalId) && result.replacement != null) {
      await _setReviewed(result.replacement!.id, true);
    }
    refresh();
    return result;
  }

  Future<void> _setReviewed(String journalId, bool reviewed) => _put(
    AppEntityTypes.transactionReview,
    journalId,
    {'id': journalId, 'reviewed': reviewed},
  );

  Future<void> markReviewed(List<String> journalIds) async {
    for (final id in journalIds) {
      await _setReviewed(id, true);
    }
    refresh();
  }

  /// Moves single-category entries to [categoryId]; returns how many were
  /// skipped because they are split or have no category.
  Future<int> categorise(List<String> journalIds, String categoryId) async {
    var skipped = 0;
    for (final id in journalIds) {
      final journal = store.journal(id);
      if (journal == null) {
        skipped++;
        continue;
      }
      final form = TransactionFormModel.fromJournal(
        chart,
        journal,
        today: today(),
      );
      if (form.splitMode ||
          form.categoryId == null ||
          !form.needsCategory ||
          chart.category(categoryId).kind !=
              chart.category(form.categoryId!).kind) {
        skipped++;
        continue;
      }
      if (form.categoryId == categoryId) continue;
      form
        ..categoryId = categoryId
        ..status = journal.status;
      await correct(id, form.toDraft());
    }
    refresh();
    return skipped;
  }

  Future<bool> undo() async {
    final undone = await store.undoLastAction();
    refresh();
    return undone;
  }

  // Accounts and setup ----------------------------------------------------

  Future<void> saveAccount(AccountEdit edit) async {
    final account = edit.account;
    if (store.account(account.id) == null) {
      await store.createAccount(account);
      _chart = null;
      final draft = edit.openingBalanceDraft();
      if (draft != null) await store.postTransaction(draft);
    } else {
      await store.updateAccount(account);
    }
    refresh();
  }

  Future<void> applyOnboarding(OnboardingResult result) async {
    for (final category in result.categories) {
      await store.createCategory(category);
    }
    for (final edit in result.accounts) {
      await store.createAccount(edit.account);
    }
    _chart = null;
    for (final edit in result.accounts) {
      final draft = edit.openingBalanceDraft();
      if (draft != null) await store.postTransaction(draft);
    }
    if (result.plan != null) {
      await _put(
        AppEntityTypes.budgetPlan,
        result.plan!.id,
        budgetPlanToJson(result.plan!),
      );
    }
    for (final schedule in result.schedules) {
      await _put(
        AppEntityTypes.recurringSchedule,
        schedule.id,
        recurringScheduleToJson(schedule),
      );
    }
    refresh();
  }

  // Planning --------------------------------------------------------------

  Future<void> savePlan(BudgetPlan plan) async {
    await _put(AppEntityTypes.budgetPlan, plan.id, budgetPlanToJson(plan));
    refresh();
  }

  Future<void> saveSchedule(RecurringSchedule schedule) async {
    await _put(
      AppEntityTypes.recurringSchedule,
      schedule.id,
      recurringScheduleToJson(schedule),
    );
    refresh();
  }

  Future<void> saveOverride(OccurrenceOverride override) async {
    await _put(
      AppEntityTypes.occurrenceOverride,
      override.id,
      occurrenceOverrideToJson(override),
    );
    refresh();
  }

  /// Links an existing journal to a bill occurrence. A journal pays at most
  /// one occurrence and a paid occurrence cannot be paid again (PLAN 02).
  Future<void> linkPayment(
    OccurrenceState state,
    Journal journal, {
    bool settles = false,
  }) async {
    final payment = OccurrencePayment(
      id: newId(),
      scheduleId: state.occurrence.scheduleId,
      occurrenceDate: state.occurrence.originalDate,
      journalId: journal.id,
      amount: journal.amount ?? state.expected,
      settles: settles,
    );
    core.linkPayment(payments, payment, state);
    await _put(
      AppEntityTypes.occurrencePayment,
      payment.id,
      occurrencePaymentToJson(payment),
    );
    refresh();
  }

  Future<Goal> saveGoal(Goal goal) async {
    await _put(AppEntityTypes.goal, goal.id, goalToJson(goal));
    refresh();
    return goal;
  }

  Future<void> allocateToGoal(
    String goalId,
    Money amount, {
    String? transferJournalId,
  }) async {
    final allocation = SavingsAllocation(
      id: newId(),
      goalId: goalId,
      date: today(),
      amount: amount,
      transferJournalId: transferJournalId,
    );
    await _put(
      AppEntityTypes.savingsAllocation,
      allocation.id,
      savingsAllocationToJson(allocation),
    );
    refresh();
  }

  Future<void> saveReservation(Reservation reservation) async {
    await _put(
      AppEntityTypes.reservation,
      reservation.id,
      reservationToJson(reservation),
    );
    refresh();
  }

  BudgetPeriodEvaluation? budgetEvaluation({LocalDate? at}) {
    final plan = budgetPlan;
    if (plan == null) return null;
    return BudgetEvaluator(
      plan: plan,
      ledger: ledger,
      adjustments: adjustments,
      savingsAllocations: savingsAllocations,
    ).evaluateAt(at ?? today());
  }

  CashForecast forecast({Scenario? scenario}) => buildCashForecast(
    ledger: ledger,
    today: today(),
    schedules: schedules,
    overrides: overrides,
    payments: payments,
    reservations: reservations,
    scenario: scenario,
  );

  /// The next confirmed payday, used as the discretionary horizon.
  LocalDate nextPayday() {
    final now = today();
    LocalDate? next;
    for (final schedule in schedules) {
      if (schedule.kind != ScheduleKind.income || !schedule.confirmed) continue;
      for (final o in schedule.occurrencesBetween(
        now.addDays(1),
        now.addDays(62),
        overrides: overrides,
      )) {
        if (!o.skipped && (next == null || o.dueDate < next)) next = o.dueDate;
      }
    }
    return next ?? now.addDays(14);
  }

  DiscretionaryEstimate discretionary() {
    final payday = nextPayday();
    final preferences = store.entity(
      AppEntityTypes.appPreferences,
      'preferences',
    );
    final buffer = preferences?.json['minimumBufferMinor'] as int?;
    return estimateDiscretionary(
      plan: budgetPlan,
      ledger: ledger,
      today: today(),
      horizonEnd: payday.addDays(-1),
      schedules: schedules,
      overrides: overrides,
      payments: payments,
      reservations: reservations,
      adjustments: adjustments,
      savingsAllocations: savingsAllocations,
      minimumBuffer: buffer == null ? null : Money(buffer, currency),
      accountDataAsOf: {
        for (final account in chart.accounts)
          if (account.dataSource == 'manual') account.id: today(),
      },
    );
  }

  List<OccurrenceState> occurrenceStates(LocalDate from, LocalDate to) {
    final statuses = {for (final j in ledger.journals) j.id: j.status};
    return [
      for (final schedule in schedules)
        for (final occurrence in schedule.occurrencesBetween(
          from,
          to,
          overrides: overrides,
        ))
          assessOccurrence(
            occurrence,
            payments: payments,
            journalStatuses: statuses,
            today: today(),
            accountDataAsOf: today(),
          ),
    ];
  }

  List<GoalProgress> goalProgress() {
    final assessment = assessReservations(reservations, ledger);
    return [
      for (final goal in goals)
        if (!goal.archived)
          core.goalProgress(
            goal,
            ledger: ledger,
            allocations: savingsAllocations,
            reservations: assessment,
          ),
    ];
  }

  /// Insights for the current budget period, with dismissed, snoozed and
  /// disabled ones removed (REP 03).
  List<Insight> insights({Set<String> receiptJournalIds = const {}}) {
    final evaluation = budgetEvaluation();
    final now = today();
    final period = evaluation == null
        ? DateRange(LocalDate(now.year, now.month, 1), now)
        : DateRange(evaluation.period.start, evaluation.period.end);
    final settingsByRule = {for (final s in ruleSettings) s.rule: s};
    final all = generateInsights(
      period: period,
      budget: evaluation,
      forecast: forecast(),
      ledger: ledger,
      lowCashThreshold:
          settingsByRule[InsightRule.lowCash]?.threshold ??
          Money.zero(currency),
      unreviewedJournalIds: unreviewedJournalIds,
      receiptJournalIds: receiptJournalIds,
      missingReceiptThreshold:
          settingsByRule[InsightRule.missingReceipt]?.threshold ??
          Money(7500, currency),
    );
    return visibleInsights(
      all,
      today: now,
      states: insightStates,
      settings: ruleSettings,
    );
  }

  Future<void> dismissInsight(Insight insight) async {
    final state = InsightState(
      id: newId(),
      insightKey: insight.key,
      dismissed: true,
    );
    await _put(
      AppEntityTypes.insightState,
      state.id,
      insightStateToJson(state),
    );
    refresh();
  }

  Future<void> snoozeInsight(Insight insight, {int days = 7}) async {
    final state = InsightState(
      id: newId(),
      insightKey: insight.key,
      snoozedUntil: today().addDays(days),
    );
    await _put(
      AppEntityTypes.insightState,
      state.id,
      insightStateToJson(state),
    );
    refresh();
  }

  Future<void> setRuleEnabled(InsightRule rule, bool enabled) async {
    final existing = ruleSettings.where((s) => s.rule == rule).firstOrNull;
    final setting = InsightRuleSetting(
      id: existing?.id ?? newId(),
      rule: rule,
      enabled: enabled,
      threshold: existing?.threshold,
    );
    await _put(
      AppEntityTypes.insightRuleSetting,
      setting.id,
      insightRuleSettingToJson(setting),
    );
    refresh();
  }
}
