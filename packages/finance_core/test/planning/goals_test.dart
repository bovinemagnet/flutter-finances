import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
      Account(id: 'savings', name: 'Savings', type: AccountType.savings),
      Account(id: 'loan', name: 'Car loan', type: AccountType.loan),
      Account(id: 'card', name: 'Card', type: AccountType.creditCard),
    ],
    categories: const [
      Category(id: 'interest', name: 'Interest', kind: CategoryKind.expense),
      Category(id: 'fees', name: 'Fees', kind: CategoryKind.expense),
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
    ],
  );
  final factory = JournalFactory(chart);

  Journal opening(String id, String account, String amount) => factory.build(
    TransactionDraft(
      id: id,
      type: TransactionType.openingBalance,
      accountId: account,
      amount: m(amount),
      effectiveDate: d('2026-07-01'),
    ),
  );

  Journal transfer(
    String id,
    String from,
    String to,
    String amount,
    String date,
  ) => factory.build(
    TransactionDraft(
      id: id,
      type: TransactionType.transfer,
      accountId: from,
      counterAccountId: to,
      amount: m(amount),
      effectiveDate: d(date),
    ),
  );

  Journal expense(String id, String account, String category, String amount) =>
      factory.build(
        TransactionDraft(
          id: id,
          type: TransactionType.expense,
          accountId: account,
          amount: m(amount),
          effectiveDate: d('2026-07-15'),
          splits: [Split(category, m(amount))],
        ),
      );

  group('goals and savings allocations (BUD 04)', () {
    final goal = Goal(
      id: 'holiday',
      name: 'Holiday',
      target: m('3000.00'),
      targetDate: d('2027-06-30'),
      linkedAccountId: 'savings',
      plannedContribution: m('250.00'),
      contributionFrequency: Frequency.monthly,
    );

    test('allocated savings are distinguished from money moved', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '5000.00'),
        transfer('t1', 'bank', 'savings', '400.00', '2026-07-05'),
      ]);
      final progress = goalProgress(
        goal,
        allocations: [
          SavingsAllocation(
            id: 'a1',
            goalId: 'holiday',
            date: d('2026-07-05'),
            amount: m('400.00'),
            transferJournalId: 't1',
          ),
          SavingsAllocation(
            id: 'a2',
            goalId: 'holiday',
            date: d('2026-07-20'),
            amount: m('250.00'),
          ),
          SavingsAllocation(
            id: 'x',
            goalId: 'other',
            date: d('2026-07-20'),
            amount: m('999.00'),
          ),
        ],
        ledger: ledger,
      );
      expect(progress.allocated, m('650.00'));
      expect(progress.moved, m('400.00'));
      expect(progress.notYetMoved, m('250.00'));
      expect(progress.remainingToTarget, m('2350.00'));
      expect(progress.allocatedBasisPoints, 2166);
      expect(ledger.expenses(d('2026-07-01'), d('2026-07-31')), m('0.00'));
    });

    test('a transfer that is still pending is not yet moved', () {
      final pendingTransfer = factory.build(
        TransactionDraft(
          id: 't1',
          type: TransactionType.transfer,
          accountId: 'bank',
          counterAccountId: 'savings',
          amount: m('100.00'),
          effectiveDate: d('2026-07-05'),
          status: JournalStatus.pending,
        ),
      );
      final progress = goalProgress(
        goal,
        allocations: [
          SavingsAllocation(
            id: 'a1',
            goalId: 'holiday',
            date: d('2026-07-05'),
            amount: m('100.00'),
            transferJournalId: 't1',
          ),
        ],
        ledger: LedgerProjection(chart, [pendingTransfer]),
      );
      expect(progress.moved, m('0.00'));
    });
  });

  group('reservations and sinking funds (BUD 05)', () {
    test('reserved amount, target and funding gap', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'savings', '1000.00'),
      ]);
      final assessment = assessReservations([
        Reservation(
          id: 'r1',
          goalId: 'insurance',
          accountId: 'savings',
          amount: m('600.00'),
        ),
      ], ledger);
      final insurance = Goal(
        id: 'insurance',
        name: 'Car insurance',
        kind: GoalKind.sinkingFund,
        target: m('900.00'),
        categoryId: 'insurance',
      );
      final progress = goalProgress(
        insurance,
        ledger: ledger,
        reservations: assessment,
      );
      expect(progress.reserved, m('600.00'));
      expect(progress.unfundedReservation, m('0.00'));
      expect(progress.fundingGap, m('300.00'));
      expect(assessment.hasUnfundedReservations, isFalse);
    });

    test('a dollar reserved for several goals is flagged as unfunded', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'savings', '1000.00'),
      ]);
      final assessment = assessReservations([
        Reservation(
          id: 'r1',
          goalId: 'a',
          accountId: 'savings',
          amount: m('700.00'),
        ),
        Reservation(
          id: 'r2',
          goalId: 'b',
          accountId: 'savings',
          amount: m('500.00'),
        ),
        Reservation(
          id: 'r3',
          goalId: 'c',
          accountId: 'savings',
          amount: m('900.00'),
          confirmed: false,
        ),
      ], ledger);
      expect(assessment.funding('r1')!.funded, m('700.00'));
      expect(assessment.funding('r2')!.funded, m('300.00'));
      expect(assessment.funding('r2')!.unfunded, m('200.00'));
      expect(assessment.funding('r2')!.isUnfunded, isTrue);
      expect(assessment.funding('r3'), isNull, reason: 'unconfirmed');
      expect(assessment.hasUnfundedReservations, isTrue);
      expect(assessment.overReservedByAccount, {'savings': m('200.00')});
      expect(assessment.reservedInAccount('savings'), m('1200.00'));
    });

    test('reservations against a liability are never funded', () {
      final ledger = LedgerProjection(chart, const []);
      final assessment = assessReservations([
        Reservation(
          id: 'r1',
          goalId: 'a',
          accountId: 'card',
          amount: m('10.00'),
        ),
      ], ledger);
      expect(assessment.funding('r1')!.unfunded, m('10.00'));
    });
  });

  group('loan presentation (BUD 06)', () {
    test('principal, interest and fees are shown separately', () {
      final ledger = LedgerProjection(chart, [
        opening('o1', 'bank', '5000.00'),
        opening('o2', 'loan', '20000.00'),
        transfer('t1', 'bank', 'loan', '500.00', '2026-07-10'),
        expense('i1', 'loan', 'interest', '80.00'),
        expense('f1', 'loan', 'fees', '5.00'),
        expense('g1', 'card', 'groceries', '50.00'),
      ]);
      final summary = summariseLoan(
        ledger,
        'loan',
        d('2026-07-01'),
        d('2026-07-31'),
        interestCategoryIds: {'interest'},
        feeCategoryIds: {'fees'},
      );
      expect(summary.principalRepaid, m('500.00'));
      expect(summary.principalJournalIds, ['t1']);
      expect(summary.interest, m('80.00'));
      expect(summary.interestJournalIds, ['i1']);
      expect(summary.fees, m('5.00'));
      expect(summary.outstanding, m('19585.00'));
    });

    test('only loans can be summarised', () {
      expect(
        () => summariseLoan(
          LedgerProjection(chart, const []),
          'card',
          d('2026-07-01'),
          d('2026-07-31'),
        ),
        throwsArgumentError,
      );
    });
  });
}
