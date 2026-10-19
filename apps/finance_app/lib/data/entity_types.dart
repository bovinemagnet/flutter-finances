/// Generic entity type names persisted through `FinanceStore.upsertEntity`
/// and synchronised as `entity.upsert` commands.
abstract final class AppEntityTypes {
  static const budgetPlan = 'budgetPlan';
  static const budgetAdjustment = 'budgetAdjustment';
  static const recurringSchedule = 'recurringSchedule';
  static const occurrenceOverride = 'occurrenceOverride';
  static const occurrencePayment = 'occurrencePayment';
  static const goal = 'goal';
  static const savingsAllocation = 'savingsAllocation';
  static const reservation = 'reservation';
  static const insightState = 'insightState';
  static const insightRuleSetting = 'insightRuleSetting';
  static const transactionReview = 'transactionReview';
  static const appPreferences = 'appPreferences';
  static const categorisationRule = 'categorisationRule';
  static const entryDraft = 'entryDraft';
  static const debtTerms = 'debtTerms';
  static const holding = 'holding';
  static const holdingEvent = 'holdingEvent';
  static const securityPrice = 'securityPrice';

  /// The workspace's single `appPreferences` entity. Synchronised entity
  /// ids must be UUIDs.
  static const appPreferencesId = '3dadac2a-0869-488b-a88b-f280642c4fc1';

  /// The single interrupted-entry draft (UX 02).
  static const entryDraftId = '6a1d1c34-7f53-4c55-9a3e-2f0f3f5b8b21';
}
