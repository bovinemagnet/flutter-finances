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

  /// Rises with every saved command. A sync never lowers it; undoing the
  /// newest action does.
  int get savedCommandMark => store.outboxHighWaterMark;
  bool isUnsynced(String type, String id) => store.isUnsynced(type, id);

  /// Call after anything outside this class changed the store, such as a
  /// sync pull.
  void refresh() {
    _chart = null;
    _ledger = null;
    _insights = null;
    _lastEntries = null;
    _budgetEvaluation = null;
    notifyListeners();
  }

  // Generic entities ------------------------------------------------------

  List<T> _all<T>(String type, T Function(Map<String, Object?> json) decode) =>
      [
        for (final record in store.entities(type))
          if (!record.deleted) decode(record.json),
      ];

  Future<void> _put(
    String type,
    String id,
    Map<String, Object?> json, {
    bool withLastAction = false,
  }) async {
    await store.upsertEntity(type, id, json, withLastAction: withLastAction);
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
      if (!record.deleted && record.json['reviewed'] == true)
        _reviewedJournal(record),
  };

  /// The entry a `transactionReview` belongs to; its id is derived from
  /// the entry's because entity ids are unique across types.
  static String _reviewedJournal(EntityRecord record) =>
      record.json['journalId'] as String? ?? record.ref.id;

  ({LocalDate today, Map<String, LocalDate> dates})? _lastEntries;

  /// The latest posted or pending entry on each account, up to today. This is
  /// how far the app actually knows an account, whatever today's date is.
  Map<String, LocalDate> get lastEntryDates {
    final now = today();
    final cached = _lastEntries;
    if (cached != null && cached.today == now) return cached.dates;
    final dates = <String, LocalDate>{};
    for (final journal in ledger.journals) {
      if (!journal.status.inPostedLedger &&
          journal.status != JournalStatus.pending) {
        continue;
      }
      final date = journal.effectiveDate;
      if (date > now) continue;
      for (final posting in journal.postings) {
        final id = posting.ledgerAccountId;
        final latest = dates[id];
        if (chart.hasAccount(id) && (latest == null || date > latest)) {
          dates[id] = date;
        }
      }
    }
    _lastEntries = (today: now, dates: dates);
    return dates;
  }

  /// What other people owe, from the ledger.
  OwedToMe get owed => owedToMe(ledger);

  /// Records money received against something paid for someone else. It goes
  /// back into [accountId] without counting as income.
  Future<void> recordRepayment(
    OwedItem item, {
    required Money amount,
    required String accountId,
    required LocalDate date,
  }) async {
    await post(
      TransactionDraft(
        type: TransactionType.reimbursement,
        accountId: accountId,
        amount: amount,
        effectiveDate: date,
        payee: item.journal.payee,
        refundOf: item.journal.id,
      ),
    );
  }

  /// Financial years with something in them, newest first, always including
  /// the current one.
  List<DateRange> get financialYears {
    final current = DateRange.financialYearContaining(today());
    var earliest = current.start.year;
    for (final journal in ledger.journals) {
      if (!journal.status.inPostedLedger) continue;
      final start = DateRange.financialYearContaining(journal.effectiveDate)
          .start
          .year;
      if (start < earliest) earliest = start;
    }
    return [
      for (var y = current.start.year; y >= earliest; y--)
        DateRange.financialYear(y),
    ];
  }

  /// How many current entries use each tag. Corrected entries and their
  /// reversals are history, so they do not count.
  Map<String, int> get tagCounts {
    final counts = <String, int>{};
    for (final journal in ledger.journals) {
      if (journal.status == JournalStatus.reversed ||
          journal.type == TransactionType.reversal) {
        continue;
      }
      for (final tag in journal.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Every tag in use, most used first.
  List<String> get knownTags {
    final counts = tagCounts;
    return counts.keys.toList()..sort((a, b) {
      final byUse = counts[b]!.compareTo(counts[a]!);
      return byUse != 0 ? byUse : a.compareTo(b);
    });
  }

  /// Renames a tag on every entry that has it, merging it into [to] when that
  /// tag exists. Only tags change, so balances and history stay as they are.
  Future<void> renameTag(String from, String to) async {
    final name = normaliseTag(to);
    if (name.isEmpty || name == from) return;
    await store.retagTransactions({
      for (final journal in ledger.journals)
        if (journal.tags.contains(from))
          journal.id: {
            for (final tag in journal.tags)
              if (tag != from) tag,
            name,
          },
    });
    refresh();
  }

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
            owedBy: draft.owedBy,
          ),
        );
      }
      refresh();
      return null;
    }
    if (draft != null && _onlyWhoOwesDiffers(existing, draft)) {
      await store.setOwedBy(journalId, draft.owedBy);
      refresh();
      return null;
    }
    final result = await store.correctTransaction(journalId, draft);
    if (reviewedJournalIds.contains(journalId) && result.replacement != null) {
      await _setReviewed(result.replacement!.id, true, withLastAction: true);
    }
    refresh();
    return result;
  }

  /// A name is not a financial change, so it needs no reversal.
  bool _onlyWhoOwesDiffers(Journal existing, TransactionDraft draft) {
    if (draft.owedBy == existing.owedBy) return false;
    final built = JournalFactory(chart).build(draft);
    return built.status == existing.status &&
        built.effectiveDate == existing.effectiveDate &&
        built.payee == existing.payee &&
        built.notes == existing.notes &&
        setEquals(built.tags, existing.tags) &&
        built.refundOf == existing.refundOf &&
        // Postings hold the amount, the accounts and so the type.
        listEquals(built.postings, existing.postings);
  }

  Future<void> _mergeReview(
    String journalId,
    Map<String, Object?> fields, {
    bool withLastAction = false,
  }) async {
    final id = ownedEntityId(AppEntityTypes.transactionReview, journalId);
    final existing = store.entity(AppEntityTypes.transactionReview, id);
    await _put(AppEntityTypes.transactionReview, id, {
      ...?existing?.json,
      'id': id,
      'journalId': journalId,
      ...fields,
    }, withLastAction: withLastAction);
  }

  Future<void> _setReviewed(
    String journalId,
    bool reviewed, {
    bool withLastAction = false,
  }) => _mergeReview(journalId, {
    'reviewed': reviewed,
  }, withLastAction: withLastAction);

  Future<void> markReviewed(List<String> journalIds) async {
    for (final id in journalIds) {
      await _setReviewed(id, true);
    }
    refresh();
  }

  /// How each entry's category was chosen; explicit user choices beat rules
  /// (AUTO 01).
  Map<String, CategorySource> get categorySources => {
    for (final record in store.entities(AppEntityTypes.transactionReview))
      if (!record.deleted && record.json['categorySource'] != null)
        _reviewedJournal(record): CategorySource.values.byName(
          record.json['categorySource'] as String,
        ),
  };

  /// Moves single-category entries to [categoryId] as the user's explicit
  /// choice; returns how many were skipped because they are split or have
  /// no category.
  Future<int> categorise(List<String> journalIds, String categoryId) async {
    var skipped = 0;
    for (final id in journalIds) {
      final journal = store.journal(id);
      final form = journal == null
          ? null
          : TransactionFormModel.fromJournal(chart, journal, today: today());
      if (form == null ||
          form.splitMode ||
          form.categoryId == null ||
          !form.needsCategory ||
          chart.category(categoryId).kind !=
              chart.category(form.categoryId!).kind) {
        skipped++;
        continue;
      }
      await _recategorise(id, categoryId, source: CategorySource.user);
    }
    refresh();
    return skipped;
  }

  /// Returns the id of the entry now carrying the category.
  Future<String?> _recategorise(
    String journalId,
    String categoryId, {
    required CategorySource source,
  }) async {
    final journal = store.journal(journalId);
    if (journal == null) return null;
    final form = TransactionFormModel.fromJournal(
      chart,
      journal,
      today: today(),
    );
    if (form.splitMode || form.categoryId == null) return null;
    var id = journalId;
    if (form.categoryId != categoryId) {
      form
        ..categoryId = categoryId
        ..status = journal.status;
      final result = await correct(journalId, form.toDraft());
      id = result?.replacement?.id ?? journalId;
    }
    await _mergeReview(id, {'categorySource': source.name});
    return id;
  }

  List<CategorisationRule> get rules => _all(
    AppEntityTypes.categorisationRule,
    (j) => categorisationRuleFromJson(j, currency),
  );

  Future<void> saveRule(CategorisationRule rule) async {
    await _put(
      AppEntityTypes.categorisationRule,
      rule.id,
      categorisationRuleToJson(rule),
    );
    refresh();
  }

  Future<void> deleteRule(String id) async {
    await store.deleteEntity(AppEntityTypes.categorisationRule, id);
    refresh();
  }

  /// What the rules would change; nothing is applied until confirmed.
  RuleApplicationPreview previewRules() => previewRuleApplication(
    rules: rules,
    journals: ledger.journals,
    chart: chart,
    categorySources: categorySources,
  );

  /// Applies confirmed rule changes as ordinary corrections and returns the
  /// reverse changes, so the whole application can be undone.
  Future<List<(String, String)>> applyRules(
    RuleApplicationPreview preview,
  ) async {
    final undo = <(String, String)>[];
    for (final change in preview.changes) {
      final id = await _recategorise(
        change.journalId,
        change.toCategoryId,
        source: CategorySource.rule,
      );
      if (id != null) undo.add((id, change.fromCategoryId));
    }
    refresh();
    return undo;
  }

  Future<void> undoRules(List<(String, String)> undo) async {
    for (final (journalId, categoryId) in undo) {
      await _recategorise(journalId, categoryId, source: CategorySource.none);
    }
    refresh();
  }

  Map<String, Object?> get _preferences =>
      store
          .entity(
            AppEntityTypes.appPreferences,
            AppEntityTypes.appPreferencesId,
          )
          ?.json ??
      const {};

  Future<void> _setPreferences(Map<String, Object?> fields) => _put(
    AppEntityTypes.appPreferences,
    AppEntityTypes.appPreferencesId,
    {..._preferences, 'id': AppEntityTypes.appPreferencesId, ...fields},
  );

  /// Saved changes to financial data, ignoring preferences and drafts.
  int get _dataChangeCount => store
      .pendingCommands()
      .where(
        (e) =>
            e.command.entityType != AppEntityTypes.appPreferences &&
            e.command.entityType != AppEntityTypes.entryDraft,
      )
      .length;

  /// The minimum cash buffer, if one has been set.
  Money? get minimumBuffer => switch (_preferences['minimumBufferMinor']) {
    final int minor => Money(minor, currency),
    _ => null,
  };

  Future<void> setMinimumBuffer(Money value) async {
    await _setPreferences({'minimumBufferMinor': value.minor});
    refresh();
  }

  /// Whether the Overview's first-use checklist was dismissed.
  bool get setupChecklistHidden => _preferences['setupChecklistHidden'] == true;

  Future<void> hideSetupChecklist() async {
    await _setPreferences({'setupChecklistHidden': true});
    refresh();
  }

  List<InboundNotice> _inboundNotices = const [];

  /// Forwarded emails that did not fully become receipts, except those the
  /// user has dismissed.
  List<InboundNotice> get inboundNotices => [
    for (final notice in _inboundNotices)
      if (store.entity(
            AppEntityTypes.inboundNoticeDismissal,
            _dismissalId(notice.messageId),
          ) ==
          null)
        notice,
  ];

  void setInboundNotices(List<InboundNotice> notices) {
    _inboundNotices = notices;
    notifyListeners();
  }

  static String _dismissalId(String messageId) =>
      ownedEntityId(AppEntityTypes.inboundNoticeDismissal, messageId);

  /// Hides a notice. Each dismissal is its own record, so members and devices
  /// never overwrite one another's.
  Future<void> dismissInboundNotice(String messageId) async {
    final id = _dismissalId(messageId);
    await _put(AppEntityTypes.inboundNoticeDismissal, id, {
      'id': id,
      'messageId': messageId,
    });
    refresh();
  }

  /// The newest balance a statement reported for an account. It is an
  /// observation kept beside the ledger: it never changes a balance, which is
  /// always calculated from entries.
  ({LocalDate date, Money balance})? balanceObservation(String accountId) {
    final record = store.entity(
      AppEntityTypes.balanceObservation,
      ownedEntityId(AppEntityTypes.balanceObservation, accountId),
    );
    if (record == null || record.deleted) return null;
    return (
      date: LocalDate.parse(record.json['date'] as String),
      balance: Money(record.json['balanceMinor'] as int, currency),
    );
  }

  /// Records what a statement reported. An older statement does not replace a
  /// newer one.
  Future<void> saveBalanceObservation(
    String accountId, {
    required LocalDate date,
    required Money balance,
  }) async {
    if (!_replacesObservation(accountId, date)) return;
    final id = ownedEntityId(AppEntityTypes.balanceObservation, accountId);
    await _put(
      AppEntityTypes.balanceObservation,
      id,
      _observationJson(id, accountId, date, balance),
    );
    refresh();
  }

  /// A statement does not replace a newer one, unless that one is dated in the
  /// future, which can only be a mistake.
  bool _replacesObservation(String accountId, LocalDate date) {
    final existing = balanceObservation(accountId);
    return existing == null || existing.date <= date || existing.date > today();
  }

  Map<String, Object?> _observationJson(
    String id,
    String accountId,
    LocalDate date,
    Money balance,
  ) => {
    'id': id,
    'accountId': accountId,
    'date': date.toString(),
    'balanceMinor': balance.minor,
  };

  /// Saves a finished reconciliation as one action, so a failure leaves nothing
  /// to adjust twice when it is finished again.
  Future<void> completeReconciliation(
    Account account, {
    required LocalDate date,
    required Money statement,
    TransactionDraft? adjustment,
  }) async {
    final id = ownedEntityId(AppEntityTypes.balanceObservation, account.id);
    // The account as it is now: it may have changed since the screen opened.
    final current = store.account(account.id) ?? account;
    final reconciled = current.lastReconciledOn;
    final keepReconciled =
        reconciled != null && reconciled > date && reconciled <= today();
    await store.saveReconciliation(
      account: keepReconciled
          ? current
          : current.copyWith(lastReconciledOn: date),
      adjustment: adjustment,
      statement: _replacesObservation(account.id, date)
          ? (
              type: AppEntityTypes.balanceObservation,
              id: id,
              json: _observationJson(id, account.id, date, statement),
            )
          : null,
    );
    refresh();
  }

  bool get appLockEnabled => _preferences['appLock'] == true;

  /// How receipt dates such as 03/04/2026 are read (OCR 04).
  DateConvention get dateConvention => DateConvention.values.byName(
    _preferences['dateConvention'] as String? ?? DateConvention.dayMonth.name,
  );

  Future<void> setDateConvention(DateConvention convention) async {
    await _setPreferences({'dateConvention': convention.name});
    refresh();
  }

  Future<void> setAppLock(bool enabled) async {
    await _setPreferences({'appLock': enabled});
    refresh();
  }

  Future<void> recordBackup({DateTime? at}) async {
    await _setPreferences({
      'lastBackupAt': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'commandsAtBackup': _dataChangeCount,
    });
    refresh();
  }

  /// A reminder for local-only data that has no recent backup (DATA 02):
  /// such data can only be recovered from a backup the user made.
  String? backupReminder({DateTime? now}) {
    if (settings.syncMode != SyncMode.local) return null;
    final changes = _dataChangeCount;
    final last = _preferences['lastBackupAt'] as String?;
    if (last == null) {
      return changes >= 10
          ? 'Your data is only on this device and has never been backed up.'
          : null;
    }
    final since = changes - (_preferences['commandsAtBackup'] as int? ?? 0);
    final days = (now ?? DateTime.now())
        .toUtc()
        .difference(DateTime.parse(last))
        .inDays;
    if (days >= 30 && since > 0) {
      return 'Your last backup was $days days ago and there are newer changes.';
    }
    if (since >= 200) {
      return 'You have made $since changes since your last backup.';
    }
    return null;
  }

  /// Fields of an entry interrupted before saving (UX 02).
  Map<String, Object?>? get entryDraft {
    final record = store.entity(
      AppEntityTypes.entryDraft,
      AppEntityTypes.entryDraftId,
    );
    return record == null || record.deleted ? null : record.json;
  }

  Future<void> saveEntryDraft(Map<String, Object?> fields) => _put(
    AppEntityTypes.entryDraft,
    AppEntityTypes.entryDraftId,
    {'id': AppEntityTypes.entryDraftId, ...fields},
  );

  Future<void> clearEntryDraft() async {
    if (entryDraft != null) {
      await store.deleteEntity(
        AppEntityTypes.entryDraft,
        AppEntityTypes.entryDraftId,
      );
    }
  }

  Future<bool> undo() async {
    final undone = await store.undoLastAction();
    refresh();
    return undone;
  }

  /// Undoes [action] only while it is still the latest, so that a later change
  /// is never reversed in its place.
  Future<bool> undoAction(UndoableAction action) async {
    if (store.lastUndoableAction?.commandId != action.commandId) return false;
    return undo();
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

  /// The budget at a date, today unless given. Only the latest answer is
  /// kept until the next [refresh]: the Overview asks for today's several
  /// times in a build, and each answer goes through every entry (NFR 02).
  BudgetPeriodEvaluation? budgetEvaluation({LocalDate? at}) {
    final date = at ?? today();
    final cached = _budgetEvaluation;
    if (cached != null && cached.date == date) return cached.evaluation;
    final plan = budgetPlan;
    final evaluation = plan == null
        ? null
        : BudgetEvaluator(
            plan: plan,
            ledger: ledger,
            adjustments: adjustments,
            savingsAllocations: savingsAllocations,
          ).evaluateAt(date);
    _budgetEvaluation = (date: date, evaluation: evaluation);
    return evaluation;
  }

  ({LocalDate date, BudgetPeriodEvaluation? evaluation})? _budgetEvaluation;

  CashForecast forecast({Scenario? scenario, LocalDate? end}) =>
      buildCashForecast(
        ledger: ledger,
        today: today(),
        end: end,
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
      minimumBuffer: minimumBuffer,
      accountDataAsOf: {
        for (final account in chart.accounts)
          if (account.dataSource == 'manual') account.id: today(),
      },
      budgetEvaluation: budgetEvaluation(),
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
  ///
  /// Worked out once per day and set of receipt-linked entries until the
  /// next [refresh], so rebuilding the Overview stays quick (NFR 02).
  List<Insight> insights({Set<String> receiptJournalIds = const {}}) {
    final now = today();
    final cached = _insights;
    if (cached != null &&
        cached.today == now &&
        setEquals(cached.receiptJournalIds, receiptJournalIds)) {
      return cached.insights;
    }
    final result = _workOutInsights(now, receiptJournalIds);
    _insights = (
      today: now,
      receiptJournalIds: Set.of(receiptJournalIds),
      insights: result,
    );
    return result;
  }

  ({LocalDate today, Set<String> receiptJournalIds, List<Insight> insights})?
  _insights;

  List<Insight> _workOutInsights(LocalDate now, Set<String> receiptJournalIds) {
    final evaluation = budgetEvaluation();
    final period = evaluation == null
        ? DateRange(LocalDate(now.year, now.month, 1), now)
        : DateRange(evaluation.period.start, evaluation.period.end);
    final settingsByRule = {for (final s in ruleSettings) s.rule: s};
    final monthStart = LocalDate(now.year, now.month, 1);
    final all = generateInsights(
      subscriptions: subscriptionProposals(),
      unusualTransactions: detectUnusualTransactions(
        ledger: ledger,
        period: period,
      ),
      spendingSpikes: detectSpendingSpikes(ledger: ledger, month: monthStart),
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

  List<DebtTerms> get debtTerms =>
      _all(AppEntityTypes.debtTerms, (j) => debtTermsFromJson(j, currency));

  Future<void> saveDebtTerms(DebtTerms terms) async {
    await _put(AppEntityTypes.debtTerms, terms.id, debtTermsToJson(terms));
    refresh();
  }

  /// Avalanche, snowball and minimum-only payoff plans for every card and
  /// loan with an amount owed and recorded terms; null when there are none.
  DebtPayoffComparison? debtPayoff({Money? extraMonthly}) {
    final terms = {for (final t in debtTerms) t.accountId: t};
    final debts = [
      for (final account in chart.accounts)
        if (account.type.isLiability &&
            !account.archived &&
            terms.containsKey(account.id) &&
            ledger.displayBalance(account.id).isPositive)
          PayoffDebt(
            id: account.id,
            name: account.name,
            balance: ledger.displayBalance(account.id),
            annualRateBasisPoints: terms[account.id]!.annualRateBasisPoints,
            minimumPayment: terms[account.id]!.minimumPayment,
          ),
    ];
    if (debts.isEmpty) return null;
    final now = today();
    return compareDebtPayoffs(
      debts: debts,
      firstPaymentDate: LocalDate(now.year, now.month, 1).addMonths(1),
      extraMonthly: extraMonthly,
    );
  }

  List<Holding> get holdings => _all(AppEntityTypes.holding, holdingFromJson);
  List<HoldingEvent> get holdingEvents =>
      _all(AppEntityTypes.holdingEvent, holdingEventFromJson);
  List<SecurityPrice> get securityPrices => _all(
    AppEntityTypes.securityPrice,
    (j) => securityPriceFromJson(j, currency),
  );

  Future<void> saveHolding(Holding holding) async {
    await _put(AppEntityTypes.holding, holding.id, holdingToJson(holding));
    refresh();
  }

  Future<void> recordHoldingEvent(HoldingEvent event) async {
    await _put(
      AppEntityTypes.holdingEvent,
      event.id,
      holdingEventToJson(event),
    );
    refresh();
  }

  /// One price per security and day; a later entry for the same day
  /// replaces the earlier one.
  Future<void> recordPrice(SecurityPrice price) async {
    final id = ownedEntityId(
      AppEntityTypes.securityPrice,
      '${price.securityCode}@${price.date}',
    );
    await _put(AppEntityTypes.securityPrice, id, {
      ...securityPriceToJson(price),
      'id': id,
    });
    refresh();
  }

  /// Detailed holdings valuation of an investment or super account (P1).
  PortfolioValuation valuation(String accountId, {LocalDate? asOf}) =>
      valuePortfolio(
        accountId: accountId,
        currency: currency,
        holdings: holdings.where((h) => h.accountId == accountId),
        events: holdingEvents,
        prices: PriceBook(securityPrices),
        asOf: asOf ?? today(),
      );

  /// A balance adjustment for the user to confirm, bringing the account to
  /// its holdings value.
  ValuationAdjustmentProposal valuationProposal(String accountId) =>
      proposeValuationAdjustment(
        ledger,
        valuation(accountId),
        draftId: newId(),
      );

  /// Merchants charging regularly that no schedule covers yet (P1).
  List<SubscriptionProposal> subscriptionProposals() => detectSubscriptions(
    ledger: ledger,
    today: today(),
    existingSchedules: schedules,
  );

  /// Confirms a detected subscription as a recurring bill.
  Future<RecurringSchedule> confirmSubscription(
    SubscriptionProposal proposal,
  ) async {
    final schedule = proposal.toSchedule(id: newId());
    await saveSchedule(schedule);
    return schedule;
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
