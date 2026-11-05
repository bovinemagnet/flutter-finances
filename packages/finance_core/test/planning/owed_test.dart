import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(int minor) => Money(minor, aud);
  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
    ],
    categories: const [
      Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
    ],
  );
  final factory = JournalFactory(chart);

  Journal paid(int minor, {String id = 'a', int day = 1, String? payee}) =>
      factory.build(
        TransactionDraft(
          id: id,
          type: TransactionType.reimbursableExpense,
          accountId: 'bank',
          amount: m(minor),
          effectiveDate: LocalDate(2026, 7, day),
          payee: payee,
        ),
      );

  Journal repaid(int minor, {String? of, String id = 'r', int day = 20}) =>
      factory.build(
        TransactionDraft(
          id: id,
          type: TransactionType.reimbursement,
          accountId: 'bank',
          amount: m(minor),
          effectiveDate: LocalDate(2026, 7, day),
          refundOf: of,
        ),
      );

  OwedToMe owed(List<Journal> journals) =>
      owedToMe(LedgerProjection(chart, journals));

  Money receivable(List<Journal> journals) => LedgerProjection(
    chart,
    journals,
  ).ledgerBalance(SystemAccounts.reimbursementReceivable);

  test('nothing is owed at first', () {
    final result = owed([]);
    expect(result.items, isEmpty);
    expect(result.total, m(0));
    expect(result.unmatched, m(0));
  });

  test('lists what is owed, oldest first', () {
    final result = owed([
      paid(2000, id: 'b', day: 9),
      paid(1000, id: 'a', day: 2),
    ]);
    expect([for (final i in result.items) i.journal.id], ['a', 'b']);
    expect(result.total, m(3000));
    expect(result.items.first.outstanding, m(1000));
    expect(result.items.first.repaid, m(0));
  });

  test('a part payment leaves the rest owing', () {
    final result = owed([paid(5000), repaid(2000, of: 'a')]);
    final item = result.items.single;
    expect(item.repaid, m(2000));
    expect(item.outstanding, m(3000));
    expect(result.total, m(3000));
  });

  test('part payments add up', () {
    final result = owed([
      paid(5000),
      repaid(2000, of: 'a', id: 'r1'),
      repaid(1000, of: 'a', id: 'r2'),
    ]);
    expect(result.items.single.outstanding, m(2000));
    expect(result.items.single.repaymentIds, ['r1', 'r2']);
  });

  test('a debt paid in full leaves the list', () {
    final result = owed([paid(5000), repaid(5000, of: 'a')]);
    expect(result.items, isEmpty);
    expect(result.total, m(0));
  });

  group('never drifts from the ledger', () {
    test('with a repayment not linked to anything', () {
      final journals = [paid(5000), repaid(2000)];
      final result = owed(journals);
      expect(result.total, receivable(journals));
      expect(result.items.single.outstanding, m(5000));
      expect(result.unmatched, m(2000));
    });

    test('when more is repaid than was owed', () {
      final journals = [paid(5000), repaid(7000, of: 'a')];
      final result = owed(journals);
      expect(result.total, receivable(journals));
      expect(result.total, m(-2000));
      expect(result.items, isEmpty);
      expect(result.unmatched, m(2000));
    });

    test('in a mixed history', () {
      final journals = [
        paid(5000),
        paid(1000, id: 'b'),
        repaid(500, of: 'a', id: 'r1'),
        repaid(100, id: 'r2'),
        repaid(1000, of: 'b', id: 'r3'),
      ];
      final result = owed(journals);
      expect(result.total, receivable(journals));
      final listed = result.items.fold(m(0), (sum, i) => sum + i.outstanding);
      expect(listed - result.unmatched, result.total);
    });
  });

  group('corrections', () {
    test('a corrected debt counts once, at its new amount', () {
      final corrected = correctJournal(paid(5000), paid(6000, id: 'new'));
      final journals = [
        corrected.original,
        corrected.reversal,
        corrected.replacement!,
      ];
      final result = owed(journals);
      expect(result.items.single.journal.id, 'new');
      expect(result.items.single.outstanding, m(6000));
      expect(result.total, receivable(journals));
    });

    test('a voided debt is no longer owed', () {
      final corrected = correctJournal(paid(5000), null);
      final result = owed([corrected.original, corrected.reversal]);
      expect(result.items, isEmpty);
      expect(result.total, m(0));
    });

    test('a repayment still counts after its debt is corrected', () {
      final first = paid(5000);
      final repayment = repaid(2000, of: first.id);
      final corrected = correctJournal(first, paid(6000, id: 'new'));
      final journals = [
        corrected.original,
        corrected.reversal,
        corrected.replacement!,
        repayment,
      ];
      final result = owed(journals);
      expect(result.items.single.outstanding, m(4000));
      expect(result.total, receivable(journals));
    });

    test('a corrected repayment counts once', () {
      final debt = paid(5000);
      final corrected = correctJournal(
        repaid(2000, of: debt.id),
        repaid(3000, of: debt.id, id: 'r2'),
      );
      final journals = [
        debt,
        corrected.original,
        corrected.reversal,
        corrected.replacement!,
      ];
      final result = owed(journals);
      expect(result.items.single.outstanding, m(2000));
      expect(result.total, receivable(journals));
    });
  });

  test('a draft or pending debt is not owed yet', () {
    final result = owed([
      factory.build(
        TransactionDraft(
          type: TransactionType.reimbursableExpense,
          status: JournalStatus.pending,
          accountId: 'bank',
          amount: m(5000),
          effectiveDate: LocalDate(2026, 7, 1),
        ),
      ),
    ]);
    expect(result.items, isEmpty);
    expect(result.total, m(0));
  });

  group('is not spending or income', () {
    final range = DateRange(LocalDate(2026, 7, 1), LocalDate(2026, 7, 31));
    final journals = [paid(5000), repaid(5000, of: 'a')];

    test('paying for someone is not your spending', () {
      final report = spendingByCategory(
        LedgerProjection(chart, journals),
        range,
      );
      expect(report.rows, isEmpty);
    });

    test('being paid back is not income', () {
      final report = incomeVsExpenses(LedgerProjection(chart, journals), range);
      expect(report.rows.single.amount('income'), m(0));
      expect(report.rows.single.amount('expenses'), m(0));
    });

    test('and leaves the money where it started', () {
      expect(LedgerProjection(chart, journals).displayBalance('bank'), m(0));
    });
  });
}
