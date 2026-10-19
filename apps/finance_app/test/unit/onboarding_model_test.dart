import 'package:finance_app/features/onboarding/onboarding_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' show SyncMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const aud = Currency.aud;

  test('defaults to Australian settings and local operation', () {
    final model = OnboardingModel(today: LocalDate(2026, 10, 19));
    expect(model.currency, aud);
    expect(model.timezone, 'Australia/Brisbane');
    expect(model.locale, 'en_AU');
    expect(model.syncMode, SyncMode.local);
    expect(model.payFrequency, Frequency.fortnightly);
  });

  test('builds a fortnightly 50/30/20 budget from take-home pay', () {
    final model = OnboardingModel(today: LocalDate(2026, 10, 19))
      ..takeHomePay = Money(312345, aud)
      ..nextPayday = LocalDate(2026, 10, 23)
      ..payAccountId = 'bank';
    final result = model.build();
    final version = result.plan!.versions.single;
    expect(result.plan!.schedule.cycle, PeriodCycle.fortnight);
    expect(result.plan!.schedule.anchor, LocalDate(2026, 10, 23));
    expect(version.income, Money(312345, aud));
    final summary = version.summary();
    // Savings has no categories yet, so its share is shown as unassigned.
    expect(summary.allocated + summary.unassigned, Money(312345, aud));
    final needs = version.allocations.where((a) => a.groupId == 'needs');
    expect(needs.fold<int>(0, (t, a) => t + a.planned.minor), 156173);
    expect(
      result.categories.where((c) => c.kind == CategoryKind.income),
      isNotEmpty,
    );
    final pay = result.schedules.single;
    expect(pay.kind, ScheduleKind.income);
    expect(pay.recurrence.frequency, Frequency.fortnightly);
    expect(pay.accountId, 'bank');
  });

  test('percentages are adjustable but must total 100%', () {
    final model = OnboardingModel(today: LocalDate(2026, 10, 19))
      ..takeHomePay = Money(500000, aud)
      ..shares = {'needs': 6000, 'wants': 2000, 'savings': 2000};
    expect(model.shareError, isNull);
    model.shares = {'needs': 6000, 'wants': 3000, 'savings': 2000};
    expect(model.shareError, contains('110%'));
  });

  test('category-only mode uses the same budget model without groups', () {
    final model = OnboardingModel(today: LocalDate(2026, 10, 19))
      ..takeHomePay = Money(400000, aud)
      ..budgetMode = BudgetMode.categoryOnly;
    final plan = model.build().plan!;
    expect(plan.mode, BudgetMode.categoryOnly);
    expect(plan.versions.single.groups, isEmpty);
    expect(plan.versions.single.allocations, isEmpty);
  });

  test('a budget is optional', () {
    final model = OnboardingModel(today: LocalDate(2026, 10, 19));
    final result = model.build();
    expect(result.plan, isNull);
    expect(result.schedules, isEmpty);
    expect(result.categories, isNotEmpty);
  });
}
