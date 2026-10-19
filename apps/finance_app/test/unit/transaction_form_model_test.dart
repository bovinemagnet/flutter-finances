import 'package:finance_app/features/transactions/transaction_form_model.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const aud = Currency.aud;
  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
      Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
      Account(id: 'cash', name: 'Wallet', type: AccountType.cash),
    ],
    categories: const [
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
      Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
      Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
    ],
  );
  final today = LocalDate(2026, 10, 19);

  TransactionFormModel model() => TransactionFormModel(chart, today: today);

  test('builds a single-category expense from a calculator amount', () {
    final form = model()
      ..accountId = 'bank'
      ..amountText = '12.50+3.25'
      ..categoryId = 'groceries'
      ..payee = 'Corner Store';
    expect(form.errors, isEmpty);
    final draft = form.toDraft();
    expect(draft.type, TransactionType.expense);
    expect(draft.amount, Money(1575, aud));
    expect(draft.splits.single.categoryId, 'groceries');
    expect(draft.effectiveDate, today);
    expect(JournalFactory(chart).build(draft).postings, hasLength(2));
  });

  test('reports missing fields by name', () {
    final form = model()..amountText = '';
    expect(
      form.errors.keys,
      containsAll([EntryField.account, EntryField.amount, EntryField.category]),
    );
  });

  test('tracks the unallocated remainder while splitting (A03)', () {
    final form = model()
      ..accountId = 'bank'
      ..amountText = '103.47'
      ..splitMode = true
      ..splits = [
        SplitLine('groceries', '80.00'),
        SplitLine('dining', '23.46'),
      ];
    expect(form.unallocated, Money(1, aud));
    expect(form.errors[EntryField.splits], contains('0.01'));
    form.splits = [
      SplitLine('groceries', '80.00'),
      SplitLine('dining', '23.47'),
    ];
    expect(form.unallocated, Money.zero(aud));
    expect(form.errors, isEmpty);
    expect(form.toDraft().splits, hasLength(2));
  });

  test('transfers need a different destination and no category', () {
    final form = model()
      ..type = TransactionType.transfer
      ..accountId = 'bank'
      ..counterAccountId = 'bank'
      ..amountText = '120';
    expect(form.errors[EntryField.counterAccount], isNotNull);
    form.counterAccountId = 'card';
    expect(form.errors, isEmpty);
    final draft = form.toDraft();
    expect(draft.counterAccountId, 'card');
    expect(draft.splits, isEmpty);
  });

  test('income only offers income categories', () {
    final form = model()..type = TransactionType.income;
    expect(form.availableCategories.map((c) => c.id), ['salary']);
    form.type = TransactionType.expense;
    expect(
      form.availableCategories.map((c) => c.id),
      containsAll(['groceries', 'dining']),
    );
  });

  test('a refund links to its original purchase', () {
    final form = model()
      ..type = TransactionType.refund
      ..accountId = 'bank'
      ..amountText = '40'
      ..categoryId = 'groceries'
      ..refundOf = 'original-id';
    expect(form.toDraft().refundOf, 'original-id');
  });

  test('a cash expense requires the cash account to be confirmed', () {
    final form = model()
      ..accountId = 'cash'
      ..amountText = '5'
      ..categoryId = 'dining'
      ..requireCashConfirmation = true;
    expect(form.errors[EntryField.account], contains('cash'));
    form.cashAccountConfirmed = true;
    expect(form.errors, isEmpty);
  });

  test('loads an existing journal for an ordinary edit', () {
    final journal = JournalFactory(chart).build(
      TransactionDraft(
        type: TransactionType.expense,
        accountId: 'card',
        amount: Money(6325, aud),
        effectiveDate: LocalDate(2026, 10, 1),
        splits: [Split('groceries', Money(6325, aud))],
        payee: 'Grocer',
        tags: {'holiday'},
      ),
    );
    final form = TransactionFormModel.fromJournal(chart, journal, today: today);
    expect(form.amountText, '63.25');
    expect(form.accountId, 'card');
    expect(form.categoryId, 'groceries');
    expect(form.tags, {'holiday'});
    expect(form.toDraft().effectiveDate, LocalDate(2026, 10, 1));
  });
}
