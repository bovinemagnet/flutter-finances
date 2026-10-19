import 'dart:io';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/features/accounts/account_editor.dart';
import 'package:finance_app/features/onboarding/onboarding_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  const aud = Currency.aud;
  late Directory dir;
  late AppState state;
  final today = LocalDate(2026, 10, 19);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('finance_app_test');
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => today);
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  Future<void> onboard() async {
    final model = OnboardingModel(today: today)
      ..takeHomePay = Money(312345, aud)
      ..nextPayday = LocalDate(2026, 10, 23);
    model.accounts.add(
      AccountEdit(
        const Account(
          id: 'bank',
          name: 'Everyday',
          type: AccountType.transaction,
        ),
        Money(400000, aud),
        LocalDate(2026, 10, 1),
      ),
    );
    model.accounts.add(
      AccountEdit(
        const Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
        Money(25000, aud),
        LocalDate(2026, 10, 1),
      ),
    );
    model.payAccountId = 'bank';
    await state.applyOnboarding(model.build());
  }

  String categoryId(String name) =>
      state.chart.categories.firstWhere((c) => c.name == name).id;

  test(
    'onboarding persists accounts, opening balances, budget and pay',
    () async {
      var notified = 0;
      state.addListener(() => notified++);
      await onboard();
      expect(notified, greaterThan(0));
      expect(state.ledger.displayBalance('bank'), Money(400000, aud));
      expect(state.ledger.displayBalance('card'), Money(25000, aud));
      expect(
        state.ledger.income(LocalDate(2026, 10, 1), today),
        Money.zero(aud),
      );
      expect(state.budgetPlan!.versions.single.income, Money(312345, aud));
      expect(state.schedules.single.kind, ScheduleKind.income);
      expect(state.unsyncedCount, greaterThan(0));
    },
  );

  test(
    'posting, review and recategorisation keep the ledger balanced',
    () async {
      await onboard();
      final journal = await state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'card',
          amount: Money(6325, aud),
          effectiveDate: today,
          splits: [Split(categoryId('Groceries'), Money(6325, aud))],
          payee: 'Fresh Grocer',
        ),
      );
      expect(state.unreviewedJournalIds, contains(journal.id));
      await state.markReviewed([journal.id]);
      expect(state.unreviewedJournalIds, isNot(contains(journal.id)));

      final skipped = await state.categorise([
        journal.id,
      ], categoryId('Dining out'));
      expect(skipped, 0);
      final from = LocalDate(2026, 10, 1);
      expect(
        state.ledger.categoryNet(categoryId('Dining out'), from, today),
        Money(6325, aud),
      );
      expect(
        state.ledger.categoryNet(categoryId('Groceries'), from, today),
        Money.zero(aud),
      );
      for (final j in state.ledger.journals) {
        expect(validatePostings(j.postings), isEmpty);
      }
    },
  );

  test('the newest unsent action can be undone', () async {
    await onboard();
    final journal = await state.post(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: Money(500, aud),
        effectiveDate: today,
        splits: [Split(categoryId('Groceries'), Money(500, aud))],
      ),
    );
    expect(await state.undo(), isTrue);
    expect(state.store.journal(journal.id), isNull);
  });

  test('derived planning views come from persisted entities', () async {
    await onboard();
    expect(state.budgetEvaluation(), isNotNull);
    expect(state.forecast().days, hasLength(90));
    final estimate = state.discretionary();
    expect(estimate.horizonEnd, LocalDate(2026, 10, 22));
    final goal = await state.saveGoal(
      Goal(id: newId(), name: 'Holiday', target: Money(300000, aud)),
    );
    await state.allocateToGoal(goal.id, Money(20000, aud));
    expect(state.goalProgress().single.allocated, Money(20000, aud));
    expect(state.occurrenceStates(today, today.addDays(30)), isNotEmpty);
    expect(state.insights(), isA<List<Insight>>());
  });

  test('insight dismissal and rule switches persist', () async {
    await onboard();
    await state.post(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: Money(500, aud),
        effectiveDate: today,
        splits: [Split(categoryId('Groceries'), Money(500, aud))],
      ),
    );
    final unreviewed = state.insights().firstWhere(
      (i) => i.rule == InsightRule.unreviewed,
    );
    await state.dismissInsight(unreviewed);
    expect(state.insights().where((i) => i.key == unreviewed.key), isEmpty);
    await state.setRuleEnabled(InsightRule.unreviewed, false);
    expect(
      state.insights().where((i) => i.rule == InsightRule.unreviewed),
      isEmpty,
    );
  });

  test(
    'rules recategorise only entries the user did not choose, with undo',
    () async {
      await onboard();
      Future<Journal> buy(String payee) => state.post(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: Money(900, aud),
          effectiveDate: today,
          payee: payee,
          splits: [Split(categoryId('Shopping'), Money(900, aud))],
        ),
      );
      await buy('Corner Cafe');
      final chosen = await buy('Corner Cafe Annex');
      await state.categorise([chosen.id], categoryId('Groceries'));
      await state.saveRule(
        CategorisationRule(
          id: 'r1',
          name: 'Cafes',
          categoryId: categoryId('Dining out'),
          merchant: 'corner cafe',
        ),
      );
      final preview = state.previewRules();
      expect(preview.changes, hasLength(1));
      final undo = await state.applyRules(preview);
      final from = LocalDate(2026, 10, 1);
      expect(
        state.ledger.categoryNet(categoryId('Dining out'), from, today),
        Money(900, aud),
      );
      expect(
        state.ledger.categoryNet(categoryId('Groceries'), from, today),
        Money(900, aud),
      );
      await state.undoRules(undo);
      expect(
        state.ledger.categoryNet(categoryId('Dining out'), from, today),
        Money.zero(aud),
      );
    },
  );

  test(
    'a what-if scenario changes the projection but never the ledger',
    () async {
      await onboard();
      final journalsBefore = state.ledger.journals.length;
      final base = state.forecast().lowestBalance;
      final scenario = Scenario(
        id: 's',
        name: 'What if',
        changes: [
          OneOffChange(
            id: 'c1',
            date: today.addDays(3),
            accountId: 'bank',
            amount: Money(-150000, aud),
          ),
        ],
      );
      final projected = state.forecast(scenario: scenario);
      expect(projected.lowestBalance, base - Money(150000, aud));
      expect(projected.includesHypothetical, isTrue);
      expect(state.ledger.journals, hasLength(journalsBefore));
      expect(state.unsyncedCount, isNot(0));
    },
  );

  test('local-only workspaces are reminded to back up (DATA 02)', () async {
    expect(state.backupReminder(now: DateTime.utc(2026, 10, 19)), isNull);
    await onboard();
    expect(
      state.backupReminder(now: DateTime.utc(2026, 10, 19)),
      contains('only on this device'),
    );
    await state.recordBackup(at: DateTime.utc(2026, 10, 19));
    expect(state.backupReminder(now: DateTime.utc(2026, 10, 20)), isNull);
    // Old but unchanged since the backup: nothing to remind about.
    expect(state.backupReminder(now: DateTime.utc(2026, 11, 25)), isNull);
    await state.post(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: Money(500, aud),
        effectiveDate: today,
        splits: [Split(categoryId('Groceries'), Money(500, aud))],
      ),
    );
    expect(
      state.backupReminder(now: DateTime.utc(2026, 11, 25)),
      contains('days'),
    );
  });

  test('regular charges are suggested as a bill the user can confirm', () async {
    await onboard();
    for (final month in [7, 8, 9, 10]) {
      await state.post(TransactionDraft(
        type: TransactionType.expense,
        accountId: 'card',
        amount: Money(1699, aud),
        effectiveDate: LocalDate(2026, month, 5),
        payee: 'StreamFlix',
        splits: [Split(categoryId('Subscriptions'), Money(1699, aud))],
      ));
    }
    final proposal = state.subscriptionProposals().single;
    expect(proposal.payee, 'StreamFlix');
    expect(state.insights().map((i) => i.rule), contains(InsightRule.possibleSubscription));
    await state.confirmSubscription(proposal);
    expect(state.schedules.where((s) => s.name == 'StreamFlix'), hasLength(1));
    expect(state.subscriptionProposals(), isEmpty);
  });
}
