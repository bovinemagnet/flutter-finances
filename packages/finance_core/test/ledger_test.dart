import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  final d1 = LocalDate(2026, 7, 1);
  final d2 = LocalDate(2026, 7, 2);
  final aug = LocalDate(2026, 8, 5);

  late Chart chart;
  late JournalFactory factory;

  setUp(() {
    chart = Chart(
      currency: aud,
      accounts: [
        Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
        Account(id: 'savings', name: 'Savings', type: AccountType.savings),
        Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
        Account(id: 'house', name: 'House', type: AccountType.property),
      ],
      categories: [
        Category(
          id: 'groceries',
          name: 'Groceries',
          kind: CategoryKind.expense,
        ),
        Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
        Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
      ],
    );
    factory = JournalFactory(chart);
  });

  Journal expense(
    String account,
    String amount,
    LocalDate date, {
    String category = 'groceries',
  }) => factory.build(
    TransactionDraft(
      type: TransactionType.expense,
      accountId: account,
      amount: m(amount),
      effectiveDate: date,
      splits: [Split(category, m(amount))],
    ),
  );

  group('journal validation', () {
    test('accepts a balanced journal', () {
      final postings = [
        Posting('groceries', m('10.00')),
        Posting('bank', m('-10.00')),
      ];
      expect(validatePostings(postings), isEmpty);
    });

    test('reports unbalanced, empty, single and mixed currency journals', () {
      expect(validatePostings([]), [LedgerError.empty]);
      expect(
        validatePostings([Posting('bank', m('1.00'))]),
        containsAll([LedgerError.tooFewPostings, LedgerError.unbalanced]),
      );
      expect(
        validatePostings([Posting('a', m('1.00')), Posting('b', m('-0.99'))]),
        [LedgerError.unbalanced],
      );
      expect(
        validatePostings([
          Posting('a', m('1.00')),
          Posting('b', Money(-100, const Currency('NZD', 2))),
        ]),
        contains(LedgerError.mixedCurrency),
      );
      expect(
        validatePostings([Posting('a', m('0')), Posting('b', m('0'))]),
        contains(LedgerError.zeroAmount),
      );
    });
  });

  group('transaction drafts', () {
    test('A01 card purchase then repayment counts the expense once', () {
      final journals = [
        factory.build(
          TransactionDraft(
            type: TransactionType.openingBalance,
            accountId: 'bank',
            amount: m('1000.00'),
            effectiveDate: d1,
          ),
        ),
        expense('card', '120.00', d2),
        factory.build(
          TransactionDraft(
            type: TransactionType.transfer,
            accountId: 'bank',
            counterAccountId: 'card',
            amount: m('120.00'),
            effectiveDate: d2,
          ),
        ),
      ];
      final ledger = LedgerProjection(chart, journals);
      expect(ledger.displayBalance('bank'), m('880.00'));
      expect(ledger.displayBalance('card'), m('0.00'));
      expect(ledger.expenses(d1, d2), m('120.00'));
      expect(ledger.income(d1, d2), m('0.00'));
    });

    test('A02 transfer to savings leaves net worth and income unchanged', () {
      final opening = factory.build(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: m('2000.00'),
          effectiveDate: d1,
        ),
      );
      final before = LedgerProjection(chart, [opening]).netWorth();
      final transfer = factory.build(
        TransactionDraft(
          type: TransactionType.transfer,
          accountId: 'bank',
          counterAccountId: 'savings',
          amount: m('500.00'),
          effectiveDate: d2,
        ),
      );
      final after = LedgerProjection(chart, [opening, transfer]);
      expect(after.netWorth(), before);
      expect(after.income(d1, d2), m('0.00'));
      expect(after.expenses(d1, d2), m('0.00'));
      expect(after.displayBalance('savings'), m('500.00'));
    });

    test('A03 splits must equal the total exactly', () {
      final ok = factory.build(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: m('103.47'),
          effectiveDate: d1,
          splits: [Split('groceries', m('80.00')), Split('dining', m('23.47'))],
        ),
      );
      expect(validatePostings(ok.postings), isEmpty);
      expect(
        () => factory.build(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: m('103.47'),
            effectiveDate: d1,
            splits: [
              Split('groceries', m('80.00')),
              Split('dining', m('23.46')),
            ],
          ),
        ),
        throwsA(
          isA<DraftException>().having(
            (e) => e.code,
            'code',
            DraftError.splitMismatch,
          ),
        ),
      );
    });

    test(
      'A04 refund next month reduces the category without rewriting July',
      () {
        final purchase = expense('bank', '100.00', d2);
        final refund = factory.build(
          TransactionDraft(
            type: TransactionType.refund,
            accountId: 'bank',
            amount: m('40.00'),
            effectiveDate: aug,
            splits: [Split('groceries', m('40.00'))],
            refundOf: purchase.id,
          ),
        );
        expect(refund.refundOf, purchase.id);
        final ledger = LedgerProjection(chart, [purchase, refund]);
        expect(
          ledger.expenses(LocalDate(2026, 7, 1), LocalDate(2026, 7, 31)),
          m('100.00'),
        );
        expect(
          ledger.expenses(LocalDate(2026, 8, 1), LocalDate(2026, 8, 31)),
          m('-40.00'),
        );
        expect(
          ledger.expenses(LocalDate(2026, 7, 1), LocalDate(2026, 8, 31)),
          m('60.00'),
        );
      },
    );

    test('opening balances post to opening equity, not income', () {
      final journal = factory.build(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'card',
          amount: m('250.00'),
          effectiveDate: d1,
        ),
      );
      final ledger = LedgerProjection(chart, [journal]);
      expect(ledger.displayBalance('card'), m('250.00'));
      expect(ledger.income(d1, d1), m('0.00'));
      expect(ledger.netWorth(), m('-250.00'));
      expect(
        journal.postings.map((p) => p.ledgerAccountId),
        contains(SystemAccounts.openingEquity),
      );
    });

    test(
      'reimbursable expenses create a receivable that a repayment clears',
      () {
        final lent = factory.build(
          TransactionDraft(
            type: TransactionType.reimbursableExpense,
            accountId: 'bank',
            amount: m('60.00'),
            effectiveDate: d1,
          ),
        );
        final repaid = factory.build(
          TransactionDraft(
            type: TransactionType.reimbursement,
            accountId: 'bank',
            amount: m('60.00'),
            effectiveDate: d2,
          ),
        );
        final ledger = LedgerProjection(chart, [lent, repaid]);
        expect(
          ledger.ledgerBalance(SystemAccounts.reimbursementReceivable),
          m('0.00'),
        );
        expect(ledger.expenses(d1, d2), m('0.00'));
      },
    );

    test('a reimbursement can instead offset an expense category', () {
      final dinner = expense('bank', '90.00', d1, category: 'dining');
      final offset = factory.build(
        TransactionDraft(
          type: TransactionType.reimbursement,
          accountId: 'bank',
          amount: m('30.00'),
          effectiveDate: d2,
          splits: [Split('dining', m('30.00'))],
        ),
      );
      final ledger = LedgerProjection(chart, [dinner, offset]);
      expect(ledger.categoryNet('dining', d1, d2), m('60.00'));
    });

    test('rejects transfers to the same account and unknown accounts', () {
      expect(
        () => factory.build(
          TransactionDraft(
            type: TransactionType.transfer,
            accountId: 'bank',
            counterAccountId: 'bank',
            amount: m('1.00'),
            effectiveDate: d1,
          ),
        ),
        throwsA(isA<DraftException>()),
      );
      expect(() => expense('nope', '1.00', d1), throwsA(isA<DraftException>()));
    });
  });

  group('status and corrections', () {
    test(
      'drafts do not affect balances; pending only affects pending view',
      () {
        final draft = factory.build(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: m('5.00'),
            effectiveDate: d1,
            splits: [Split('groceries', m('5.00'))],
            status: JournalStatus.draft,
          ),
        );
        final pending = factory.build(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: m('7.00'),
            effectiveDate: d1,
            splits: [Split('groceries', m('7.00'))],
            status: JournalStatus.pending,
          ),
        );
        final ledger = LedgerProjection(chart, [draft, pending]);
        expect(ledger.displayBalance('bank'), m('0.00'));
        expect(ledger.displayBalance('bank', includePending: true), m('-7.00'));
        expect(ledger.pendingExpenses(d1, d1), m('7.00'));
      },
    );

    test('a correction keeps history with a reversal and replacement', () {
      final original = expense('bank', '63.25', d1);
      final result = correctJournal(
        original,
        factory.build(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: m('36.25'),
            effectiveDate: d1,
            splits: [Split('groceries', m('36.25'))],
          ),
        ),
      );
      expect(result.original.status, JournalStatus.reversed);
      expect(result.reversal.reversalOf, original.id);
      expect(result.replacement!.replaces, original.id);
      expect(validatePostings(result.reversal.postings), isEmpty);
      final ledger = LedgerProjection(chart, [
        result.original,
        result.reversal,
        result.replacement!,
      ]);
      expect(ledger.displayBalance('bank'), m('-36.25'));
      expect(ledger.expenses(d1, d1), m('36.25'));
    });

    test('cannot correct a journal that is already reversed', () {
      final original = expense('bank', '1.00', d1);
      final once = correctJournal(original, expense('bank', '2.00', d1));
      expect(
        () => correctJournal(once.original, expense('bank', '3.00', d1)),
        throwsStateError,
      );
    });
  });

  group('net worth and inclusion', () {
    test('excluded accounts are left out of net worth', () {
      final excluded = chart.withAccount(
        chart.account('house').copyWith(includeInNetWorth: false),
      );
      final valuation = JournalFactory(excluded).build(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'house',
          amount: m('800000.00'),
          effectiveDate: d1,
        ),
      );
      expect(LedgerProjection(chart, [valuation]).netWorth(), m('800000.00'));
      expect(LedgerProjection(excluded, [valuation]).netWorth(), m('0.00'));
      expect(LedgerProjection(chart, [valuation]).liquidMoney(), m('0.00'));
    });
  });

  group('reconciliation', () {
    test('A07-style balances: difference and completion rules', () {
      final opening = factory.build(
        TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: 'bank',
          amount: m('500.00'),
          effectiveDate: d1,
        ),
      );
      final groceries = expense('bank', '63.25', d2);
      final ledger = LedgerProjection(chart, [opening, groceries]);
      final session = Reconciliation(
        accountId: 'bank',
        statementDate: d2,
        statementBalance: m('436.75'),
        clearedJournalIds: {opening.id, groceries.id},
      );
      expect(session.difference(ledger), m('0.00'));
      expect(session.complete(ledger, factory).adjustment, isNull);

      final off = Reconciliation(
        accountId: 'bank',
        statementDate: d2,
        statementBalance: m('430.00'),
        clearedJournalIds: {opening.id, groceries.id},
      );
      expect(off.difference(ledger), m('-6.75'));
      expect(
        () => off.complete(ledger, factory),
        throwsA(isA<ReconciliationException>()),
      );
      final done = off.complete(ledger, factory, confirmAdjustment: true);
      expect(done.adjustment, isNotNull);
      final adjusted = LedgerProjection(chart, [
        opening,
        groceries,
        done.adjustment!,
      ]);
      expect(adjusted.displayBalance('bank'), m('430.00'));
      expect(adjusted.expenses(d1, d2), m('63.25'));
    });

    test('ignores cleared entries dated after the statement', () {
      final late = expense('bank', '10.00', aug);
      final ledger = LedgerProjection(chart, [late]);
      final session = Reconciliation(
        accountId: 'bank',
        statementDate: d2,
        statementBalance: m('0.00'),
        clearedJournalIds: {late.id},
      );
      expect(session.difference(ledger), m('0.00'));
    });
  });
}
