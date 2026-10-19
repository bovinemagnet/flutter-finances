import 'package:finance_core/finance_core.dart';

const aud = Currency.aud;

Money m(String text) => Money.parse(text, aud);

LocalDate d(String text) => LocalDate.parse(text);

final testChart = Chart(
  currency: aud,
  accounts: const [
    Account(id: 'bank', name: 'Everyday', type: AccountType.transaction),
    Account(id: 'savings', name: 'Savings', type: AccountType.savings),
    Account(id: 'card', name: 'Visa', type: AccountType.creditCard),
    Account(id: 'cash', name: 'Wallet', type: AccountType.cash),
  ],
  categories: const [
    Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
    Category(id: 'dining', name: 'Dining', kind: CategoryKind.expense),
    Category(id: 'fuel', name: 'Fuel', kind: CategoryKind.expense),
    Category(
      id: 'uncategorised',
      name: 'Uncategorised',
      kind: CategoryKind.expense,
    ),
    Category(id: 'salary', name: 'Salary', kind: CategoryKind.income),
    Category(
      id: 'other-income',
      name: 'Other income',
      kind: CategoryKind.income,
    ),
  ],
);

Journal expense(
  String id,
  String amount,
  String date, {
  String account = 'bank',
  String category = 'groceries',
  String? payee,
  JournalStatus status = JournalStatus.posted,
}) => JournalFactory(testChart).build(
  TransactionDraft(
    id: id,
    type: TransactionType.expense,
    accountId: account,
    amount: m(amount),
    effectiveDate: d(date),
    splits: [Split(category, m(amount))],
    payee: payee,
    status: status,
    enteredAt: DateTime.utc(2026, 7, 1),
  ),
);
