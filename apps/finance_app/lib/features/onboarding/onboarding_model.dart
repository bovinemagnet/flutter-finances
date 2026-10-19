import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' show SyncMode;

import '../accounts/account_editor.dart';

/// A starter category and the budget group it belongs to.
class StarterCategory {
  const StarterCategory(this.name, this.kind, {this.groupId, this.weight = 1});
  final String name;
  final CategoryKind kind;
  final String? groupId;
  final int weight;
}

const starterCategories = [
  StarterCategory(
    'Rent or mortgage',
    CategoryKind.expense,
    groupId: 'needs',
    weight: 40,
  ),
  StarterCategory(
    'Groceries',
    CategoryKind.expense,
    groupId: 'needs',
    weight: 20,
  ),
  StarterCategory(
    'Utilities',
    CategoryKind.expense,
    groupId: 'needs',
    weight: 10,
  ),
  StarterCategory(
    'Transport and fuel',
    CategoryKind.expense,
    groupId: 'needs',
    weight: 10,
  ),
  StarterCategory(
    'Insurance',
    CategoryKind.expense,
    groupId: 'needs',
    weight: 10,
  ),
  StarterCategory('Health', CategoryKind.expense, groupId: 'needs', weight: 10),
  StarterCategory(
    'Dining out',
    CategoryKind.expense,
    groupId: 'wants',
    weight: 30,
  ),
  StarterCategory(
    'Entertainment',
    CategoryKind.expense,
    groupId: 'wants',
    weight: 25,
  ),
  StarterCategory(
    'Shopping',
    CategoryKind.expense,
    groupId: 'wants',
    weight: 30,
  ),
  StarterCategory(
    'Subscriptions',
    CategoryKind.expense,
    groupId: 'wants',
    weight: 15,
  ),
  StarterCategory('Fees and interest', CategoryKind.expense),
  StarterCategory('Salary and wages', CategoryKind.income),
  StarterCategory('Other income', CategoryKind.income),
];

const defaultGroups = [
  BudgetGroup(id: 'needs', name: 'Needs', shareBasisPoints: 5000),
  BudgetGroup(
    id: 'wants',
    name: 'Wants',
    shareBasisPoints: 3000,
    discretionary: true,
  ),
  BudgetGroup(
    id: 'savings',
    name: 'Savings and debt reduction',
    shareBasisPoints: 2000,
  ),
];

class OnboardingResult {
  OnboardingResult({
    required this.currency,
    required this.timezone,
    required this.locale,
    required this.syncMode,
    required this.accounts,
    required this.categories,
    required this.plan,
    required this.schedules,
  });

  final Currency currency;
  final String timezone;
  final String locale;
  final SyncMode syncMode;
  final List<AccountEdit> accounts;
  final List<Category> categories;
  final BudgetPlan? plan;
  final List<RecurringSchedule> schedules;
}

/// Choices made during first-run setup (Journey A). A useful budget needs no
/// bank connection: take-home pay, a pay cycle and a template are enough.
class OnboardingModel {
  OnboardingModel({required this.today});

  final LocalDate today;
  Currency currency = Currency.aud;
  String timezone = 'Australia/Brisbane';
  String locale = 'en_AU';
  SyncMode syncMode = SyncMode.local;
  final List<AccountEdit> accounts = [];

  /// Take-home pay per pay cycle; tax is never estimated (BUD 01).
  Money? takeHomePay;
  Frequency payFrequency = Frequency.fortnightly;
  LocalDate? nextPayday;
  String? payAccountId;
  BudgetMode budgetMode = BudgetMode.groups;
  Map<String, int> shares = {
    for (final g in defaultGroups) g.id: g.shareBasisPoints,
  };

  String? get shareError {
    final total = shares.values.fold<int>(0, (a, b) => a + b);
    if (total == fullShareBasisPoints) return null;
    return 'Shares add up to ${total ~/ 100}%; they must total 100%';
  }

  PeriodCycle get _cycle => switch (payFrequency) {
    Frequency.weekly => PeriodCycle.week,
    Frequency.fortnightly => PeriodCycle.fortnight,
    _ => PeriodCycle.month,
  };

  OnboardingResult build() {
    final categories = <Category>[];
    final weights = <String, Map<String, int>>{};
    for (final starter in starterCategories) {
      final category = Category(
        id: newId(),
        name: starter.name,
        kind: starter.kind,
      );
      categories.add(category);
      if (starter.groupId != null) {
        (weights[starter.groupId!] ??= {})[category.id] = starter.weight;
      }
    }

    BudgetPlan? plan;
    final schedules = <RecurringSchedule>[];
    final pay = takeHomePay;
    if (pay != null && pay.isPositive) {
      final anchor = nextPayday ?? today;
      final groups = [
        for (final g in defaultGroups)
          BudgetGroup(
            id: g.id,
            name: g.name,
            shareBasisPoints: shares[g.id] ?? g.shareBasisPoints,
            discretionary: g.discretionary,
          ),
      ];
      final version = budgetMode == BudgetMode.groups
          ? BudgetVersion.fromTemplate(
              id: newId(),
              effectiveFrom: anchor,
              income: pay,
              groups: groups,
              categoryWeights: weights,
            )
          : BudgetVersion(id: newId(), effectiveFrom: anchor, income: pay);
      plan = BudgetPlan(
        id: newId(),
        name: 'My budget',
        mode: budgetMode,
        schedule: PeriodSchedule(
          cycle: _cycle,
          anchor: anchor,
          timezone: timezone,
          rollover: RolloverPolicy.positiveOnly,
        ),
        versions: [version],
      );
      if (payAccountId != null) {
        schedules.add(
          RecurringSchedule(
            id: newId(),
            name: 'Pay',
            kind: ScheduleKind.income,
            recurrence: Recurrence(frequency: payFrequency, start: anchor),
            amount: pay,
            accountId: payAccountId!,
            categoryId: categories
                .firstWhere((c) => c.name == 'Salary and wages')
                .id,
          ),
        );
      }
    }

    return OnboardingResult(
      currency: currency,
      timezone: timezone,
      locale: locale,
      syncMode: syncMode,
      accounts: List.unmodifiable(accounts),
      categories: categories,
      plan: plan,
      schedules: schedules,
    );
  }
}
