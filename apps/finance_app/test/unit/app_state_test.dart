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

  group('undoing a particular action', () {
    TransactionDraft expense(int minor) => TransactionDraft(
      type: TransactionType.expense,
      accountId: 'bank',
      amount: Money(minor, aud),
      effectiveDate: today,
      splits: [Split(categoryId('Groceries'), Money(minor, aud))],
    );

    test('undoes it while it is still the latest', () async {
      await onboard();
      final journal = await state.post(expense(500));
      final action = state.store.lastUndoableAction!;
      expect(await state.undoAction(action), isTrue);
      expect(state.store.journal(journal.id), isNull);
    });

    test('never reverses a later action in its place', () async {
      await onboard();
      final journal = await state.post(expense(500));
      final action = state.store.lastUndoableAction!;
      await state.markReviewed([journal.id]);
      expect(await state.undoAction(action), isFalse);
      expect(state.store.journal(journal.id), isNotNull);
      expect(state.reviewedJournalIds, contains(journal.id));
    });

    test('takes back a correction of a reviewed entry whole', () async {
      await onboard();
      final journal = await state.post(expense(500));
      await state.markReviewed([journal.id]);
      final result = await state.correct(journal.id, expense(700));
      final action = state.store.lastUndoableAction!;
      expect(action.type, CommandType.journalCorrect);
      expect(await state.undoAction(action), isTrue);
      expect(state.store.journal(journal.id)!.status, JournalStatus.posted);
      expect(state.store.journal(result!.replacement!.id), isNull);
      expect(state.reviewedJournalIds, contains(journal.id));
      expect(state.reviewedJournalIds, isNot(contains(result.replacement!.id)));
    });
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

  test('the budget is worked out once until something changes', () async {
    await onboard();
    final first = state.budgetEvaluation()!;
    expect(identical(state.budgetEvaluation(), first), isTrue);
    expect(identical(state.budgetEvaluation(at: today), first), isTrue);

    // A saved entry counts straight away.
    await state.post(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'bank',
        amount: Money(500, aud),
        effectiveDate: today,
        splits: [Split(categoryId('Groceries'), Money(500, aud))],
      ),
    );
    final afterEntry = state.budgetEvaluation()!;
    expect(identical(afterEntry, first), isFalse);
    int spent(BudgetPeriodEvaluation e) => [...e.lines, ...e.unbudgeted]
        .where((l) => l.targetId == categoryId('Groceries'))
        .fold(0, (total, l) => total + l.postedNet.minor);
    expect(spent(afterEntry), spent(first) + 500);

    // So does a changed plan.
    final plan = state.budgetPlan!;
    await state.savePlan(
      BudgetPlan(
        id: plan.id,
        name: 'Renamed',
        mode: plan.mode,
        schedule: plan.schedule,
        versions: plan.versions,
      ),
    );
    expect(identical(state.budgetEvaluation(), afterEntry), isFalse);

    // Another date gets its own answer, and today's is still right after it.
    final earlier = today.addMonths(-3);
    final other = state.budgetEvaluation(at: earlier);
    expect(other!.period.contains(today), isFalse);
    expect(state.budgetEvaluation()!.period.contains(today), isTrue);
  });

  test('tomorrow gets its own budget without a refresh', () async {
    var now = today;
    await state.store.close();
    final store = await FinanceStore.open(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    state = AppState(store, today: () => now);
    await onboard();
    final before = state.budgetEvaluation()!;
    now = before.period.end.addDays(1);
    expect(state.budgetEvaluation()!.period.contains(now), isTrue);
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
    'insights are worked out once until the state changes (NFR 02)',
    () async {
      await onboard();
      final first = state.insights();
      expect(state.insights(), same(first));
      expect(state.insights(receiptJournalIds: {'j1'}), isNot(same(first)));
      final withReceipt = state.insights(receiptJournalIds: {'j1'});
      expect(state.insights(receiptJournalIds: {'j1'}), same(withReceipt));
      state.refresh();
      expect(
        state.insights(receiptJournalIds: {'j1'}),
        isNot(same(withReceipt)),
      );
    },
  );

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

  test(
    'regular charges are suggested as a bill the user can confirm',
    () async {
      await onboard();
      for (final month in [7, 8, 9, 10]) {
        await state.post(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'card',
            amount: Money(1699, aud),
            effectiveDate: LocalDate(2026, month, 5),
            payee: 'StreamFlix',
            splits: [Split(categoryId('Subscriptions'), Money(1699, aud))],
          ),
        );
      }
      final proposal = state.subscriptionProposals().single;
      expect(proposal.payee, 'StreamFlix');
      expect(
        state.insights().map((i) => i.rule),
        contains(InsightRule.possibleSubscription),
      );
      await state.confirmSubscription(proposal);
      expect(
        state.schedules.where((s) => s.name == 'StreamFlix'),
        hasLength(1),
      );
      expect(state.subscriptionProposals(), isEmpty);
    },
  );

  test('debt payoff strategies compare the user\'s cards and loans', () async {
    await onboard();
    final card = state.chart.accounts.firstWhere((a) => a.id == 'card');
    await state.saveDebtTerms(
      DebtTerms(
        id: newId(),
        accountId: card.id,
        annualRateBasisPoints: 2099,
        minimumPayment: Money(2500, aud),
      ),
    );
    final comparison = state.debtPayoff(extraMonthly: Money(10000, aud))!;
    expect(
      comparison.avalanche.totalInterest <=
          comparison.minimumOnly.totalInterest,
      isTrue,
    );
    expect(comparison.avalanche.payoffDates[card.id], isNotNull);
  });

  test('holdings value an investment account and propose an update', () async {
    await onboard();
    await state.saveAccount(
      AccountEdit(
        const Account(
          id: 'shares',
          name: 'Shares',
          type: AccountType.investment,
        ),
        Money(1000000, aud),
        LocalDate(2026, 10, 1),
      ),
    );
    final holding = Holding(
      id: newId(),
      securityCode: 'VAS',
      name: 'Australian shares',
      accountId: 'shares',
    );
    await state.saveHolding(holding);
    await state.recordHoldingEvent(
      HoldingEvent.buy(
        id: newId(),
        holdingId: holding.id,
        date: LocalDate(2026, 10, 2),
        units: parseUnits('100'),
      ),
    );
    await state.recordPrice(
      SecurityPrice(
        securityCode: 'VAS',
        date: LocalDate(2026, 10, 18),
        price: Money(12000, aud),
      ),
    );
    final valuation = state.valuation('shares');
    expect(valuation.total, Money(1200000, aud));
    final proposal = state.valuationProposal('shares');
    expect(proposal.draft, isNotNull);
    await state.post(proposal.draft!);
    expect(state.ledger.displayBalance('shares'), Money(1200000, aud));
  });

  group('who owes a debt', () {
    Future<Journal> debt({String? owedBy}) async {
      await onboard();
      return state.post(
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          accountId: 'bank',
          amount: Money(4000, aud),
          effectiveDate: today,
          payee: 'Concert',
          owedBy: owedBy,
        ),
      );
    }

    TransactionDraft edited(
      Journal journal, {
      String? owedBy,
      int minor = 4000,
      String payee = 'Concert',
      String account = 'bank',
      LocalDate? date,
      String? notes,
      Set<String> tags = const {},
      String? refundOf,
      JournalStatus status = JournalStatus.posted,
    }) => TransactionDraft(
      type: journal.type,
      accountId: account,
      amount: Money(minor, aud),
      effectiveDate: date ?? journal.effectiveDate,
      payee: payee,
      owedBy: owedBy,
      notes: notes,
      tags: tags,
      refundOf: refundOf,
      status: status,
    );

    for (final (what, change) in <(String, TransactionDraft Function(Journal))>[
      ('amount', (j) => edited(j, owedBy: 'Sam', minor: 5000)),
      ('account', (j) => edited(j, owedBy: 'Sam', account: 'card')),
      ('date', (j) => edited(j, owedBy: 'Sam', date: LocalDate(2026, 10, 18))),
      ('payee', (j) => edited(j, owedBy: 'Sam', payee: 'Dinner')),
      ('notes', (j) => edited(j, owedBy: 'Sam', notes: 'Row F')),
      ('tags', (j) => edited(j, owedBy: 'Sam', tags: {'holiday'})),
      ('link', (j) => edited(j, owedBy: 'Sam', refundOf: 'other')),
    ]) {
      test('a new name and $what together are still a correction', () async {
        final journal = await debt();
        final result = await state.correct(journal.id, change(journal));
        expect(result?.replacement?.owedBy, 'Sam');
      });
    }

    test('a new name and status are not only a name', () async {
      final journal = await debt();
      await expectLater(
        state.correct(
          journal.id,
          edited(journal, owedBy: 'Sam', status: JournalStatus.pending),
        ),
        completion(isNotNull),
      );
    });

    test('adding a name does not reverse the entry', () async {
      final journal = await debt();
      final count = state.ledger.journals.length;
      final result = await state.correct(
        journal.id,
        edited(journal, owedBy: 'Sam'),
      );
      expect(result, isNull);
      expect(state.ledger.journals, hasLength(count));
      final item = state.owed.items.single;
      expect(item.journal.id, journal.id);
      expect(item.journal.owedBy, 'Sam');
    });

    test('a name can be changed or taken off the same way', () async {
      final journal = await debt(owedBy: 'Sam');
      final count = state.ledger.journals.length;
      await state.correct(journal.id, edited(journal, owedBy: 'Alex'));
      expect(state.owed.items.single.journal.owedBy, 'Alex');
      await state.correct(journal.id, edited(journal));
      expect(state.owed.items.single.journal.owedBy, isNull);
      expect(state.ledger.journals, hasLength(count));
    });

    test('changing a name can be undone', () async {
      final journal = await debt(owedBy: 'Sam');
      await state.correct(journal.id, edited(journal, owedBy: 'Alex'));
      expect(await state.undo(), isTrue);
      expect(state.owed.items.single.journal.owedBy, 'Sam');
    });

    test(
      'changing the amount is still a correction, keeping the name',
      () async {
        final journal = await debt(owedBy: 'Sam');
        final result = await state.correct(
          journal.id,
          edited(journal, owedBy: 'Sam', minor: 5000),
        );
        expect(result!.replacement, isNotNull);
        final item = state.owed.items.single;
        expect(item.journal.id, result.replacement!.id);
        expect(item.journal.owedBy, 'Sam');
        expect(item.outstanding, Money(5000, aud));
      },
    );

    test('changing the payee and the name is still a correction', () async {
      final journal = await debt();
      final result = await state.correct(
        journal.id,
        edited(journal, owedBy: 'Sam', payee: 'Dinner'),
      );
      expect(result!.replacement!.owedBy, 'Sam');
      expect(state.owed.items.single.journal.payee, 'Dinner');
    });

    test('saving with nothing changed behaves as it always has', () async {
      final journal = await debt(owedBy: 'Sam');
      final result = await state.correct(
        journal.id,
        edited(journal, owedBy: 'Sam'),
      );
      expect(result!.replacement!.owedBy, 'Sam');
    });

    test('a repayment stays with the debt when the name changes', () async {
      final journal = await debt();
      await state.recordRepayment(
        state.owed.items.single,
        amount: Money(1000, aud),
        accountId: 'bank',
        date: today,
      );
      await state.correct(journal.id, edited(journal, owedBy: 'Sam'));
      final item = state.owed.items.single;
      expect(item.outstanding, Money(3000, aud));
      expect(item.journal.owedBy, 'Sam');
    });

    test('a pending debt keeps its name when saved again', () async {
      await onboard();
      final pending = await state.post(
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          status: JournalStatus.pending,
          accountId: 'bank',
          amount: Money(4000, aud),
          effectiveDate: today,
          owedBy: 'Sam',
        ),
      );
      await state.correct(
        pending.id,
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          status: JournalStatus.pending,
          accountId: 'bank',
          amount: Money(5000, aud),
          effectiveDate: today,
          owedBy: 'Alex',
        ),
      );
      expect(state.store.journal(pending.id)!.owedBy, 'Alex');
    });
  });
}
