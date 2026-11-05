import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(int minor) => Money(minor, aud);
  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
      Account(id: 'save', name: 'Savings', type: AccountType.savings),
    ],
    categories: const [
      Category(id: 'food', name: 'Food', kind: CategoryKind.expense),
      Category(id: 'fun', name: 'Fun', kind: CategoryKind.expense),
      Category(id: 'pay', name: 'Pay', kind: CategoryKind.income),
    ],
  );
  final factory = JournalFactory(chart);
  final range = DateRange(LocalDate(2026, 7, 1), LocalDate(2026, 7, 31));

  Journal expense(
    int minor, {
    Set<String> tags = const {},
    int day = 10,
    String id = '',
    List<Split>? splits,
  }) => factory.build(
    TransactionDraft(
      id: id.isEmpty ? null : id,
      type: TransactionType.expense,
      accountId: 'bank',
      amount: m(minor),
      effectiveDate: LocalDate(2026, 7, day),
      splits: splits ?? [Split('food', m(minor))],
      tags: tags,
    ),
  );

  Report report(List<Journal> journals) =>
      spendingByTag(LedgerProjection(chart, journals), range);

  test('adds up spending per tag, largest first', () {
    final result = report([
      expense(1000, tags: {'holiday'}),
      expense(2500, tags: {'holiday'}),
      expense(9000, tags: {'renovation'}),
      expense(4000),
    ]);
    expect([for (final r in result.rows) r.key], ['renovation', 'holiday']);
    expect(result.row('holiday')!.amount('spending'), m(3500));
    expect(result.row('renovation')!.amount('spending'), m(9000));
  });

  test('lists the entries behind each tag, for opening them', () {
    final a = expense(1000, tags: {'holiday'}, id: 'a');
    final b = expense(2000, tags: {'holiday'}, id: 'b', day: 11);
    final result = report([a, b, expense(500, id: 'c')]);
    expect(result.row('holiday')!.journalIds, ['a', 'b']);
  });

  test('counts every split of a tagged entry', () {
    final result = report([
      expense(
        3000,
        tags: {'holiday'},
        splits: [Split('food', m(1000)), Split('fun', m(2000))],
      ),
    ]);
    expect(result.row('holiday')!.amount('spending'), m(3000));
  });

  test('counts an entry under each of its tags, and says so', () {
    final result = report([
      expense(1000, tags: {'holiday', 'kids'}),
    ]);
    expect(result.row('holiday')!.amount('spending'), m(1000));
    expect(result.row('kids')!.amount('spending'), m(1000));
    expect(result.note, contains('more than one tag'));
  });

  test('leaves out dates outside the range', () {
    final result = report([
      factory.build(
        TransactionDraft(
          type: TransactionType.expense,
          accountId: 'bank',
          amount: m(1000),
          effectiveDate: LocalDate(2026, 8, 1),
          splits: [Split('food', m(1000))],
          tags: const {'holiday'},
        ),
      ),
    ]);
    expect(result.rows, isEmpty);
  });

  group('counts only real spending', () {
    test('a transfer is not spending', () {
      final result = report([
        factory.build(
          TransactionDraft(
            type: TransactionType.transfer,
            accountId: 'bank',
            counterAccountId: 'save',
            amount: m(5000),
            effectiveDate: LocalDate(2026, 7, 10),
            tags: const {'holiday'},
          ),
        ),
      ]);
      expect(result.rows, isEmpty);
    });

    test('income is not spending', () {
      final result = report([
        factory.build(
          TransactionDraft(
            type: TransactionType.income,
            accountId: 'bank',
            amount: m(5000),
            effectiveDate: LocalDate(2026, 7, 10),
            splits: [Split('pay', m(5000))],
            tags: const {'holiday'},
          ),
        ),
      ]);
      expect(result.rows, isEmpty);
    });

    test('money paid for someone else is not spending', () {
      final result = report([
        factory.build(
          TransactionDraft(
            type: TransactionType.reimbursableExpense,
            accountId: 'bank',
            amount: m(5000),
            effectiveDate: LocalDate(2026, 7, 10),
            tags: const {'holiday'},
          ),
        ),
      ]);
      expect(result.rows, isEmpty);
    });

    test('a draft or pending entry is not spending yet', () {
      final result = report([
        factory.build(
          TransactionDraft(
            type: TransactionType.expense,
            status: JournalStatus.pending,
            accountId: 'bank',
            amount: m(5000),
            effectiveDate: LocalDate(2026, 7, 10),
            splits: [Split('food', m(5000))],
            tags: const {'holiday'},
          ),
        ),
      ]);
      expect(result.rows, isEmpty);
    });
  });

  group('refunds', () {
    Journal refund(int minor, {String? of, Set<String> tags = const {}}) =>
        factory.build(
          TransactionDraft(
            type: TransactionType.refund,
            accountId: 'bank',
            amount: m(minor),
            effectiveDate: LocalDate(2026, 7, 20),
            splits: [Split('food', m(minor))],
            refundOf: of,
            tags: tags,
          ),
        );

    test('reduce the tag when tagged themselves', () {
      final result = report([
        expense(5000, tags: {'holiday'}),
        refund(2000, tags: {'holiday'}),
      ]);
      expect(result.row('holiday')!.amount('spending'), m(3000));
    });

    test('reduce the tag of the purchase they refund', () {
      final result = report([
        expense(5000, tags: {'holiday'}, id: 'trip'),
        refund(2000, of: 'trip'),
      ]);
      expect(result.row('holiday')!.amount('spending'), m(3000));
      expect(result.row('holiday')!.journalIds, hasLength(2));
    });

    test('count once when tagged the same as their purchase', () {
      final result = report([
        expense(5000, tags: {'holiday'}, id: 'trip'),
        refund(2000, of: 'trip', tags: {'holiday'}),
      ]);
      expect(result.row('holiday')!.amount('spending'), m(3000));
    });
  });

  group('a corrected entry counts once', () {
    test('as its replacement, with the replacement\'s tags', () {
      final original = expense(5000, tags: {'holiday'}, id: 'orig');
      final corrected = correctJournal(
        original,
        expense(7000, tags: {'work'}, id: 'new'),
      );
      final result = report([
        corrected.original,
        corrected.reversal,
        corrected.replacement!,
      ]);
      expect(result.row('holiday'), isNull);
      expect(result.row('work')!.amount('spending'), m(7000));
    });

    test('not at all when voided', () {
      final corrected = correctJournal(
        expense(5000, tags: {'holiday'}, id: 'orig'),
        null,
      );
      final result = report([corrected.original, corrected.reversal]);
      expect(result.rows, isEmpty);
    });
  });
}
