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
}
