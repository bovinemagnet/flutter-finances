import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';

/// The accounting nature of a ledger account. Never shown to users.
enum LedgerKind { asset, liability, equity, income, expense }

/// What a user calls an account (FIN 01).
enum AccountType {
  transaction,
  savings,
  cash,
  creditCard,
  loan,
  property,
  investment,
  superannuation,
  otherAsset;

  bool get isLiability => this == creditCard || this == loan;

  /// Money that can be spent without selling or redeeming anything.
  bool get isLiquid => this == transaction || this == savings || this == cash;

  LedgerKind get ledgerKind =>
      isLiability ? LedgerKind.liability : LedgerKind.asset;
}

@immutable
class Account {
  const Account({
    required this.id,
    required this.name,
    required this.type,
    this.includeInBudget = true,
    this.includeInForecast = true,
    this.includeInNetWorth = true,
    this.archived = false,
    this.dataSource = 'manual',
    this.lastReconciledOn,
  });

  final String id;
  final String name;
  final AccountType type;
  final bool includeInBudget;
  final bool includeInForecast;
  final bool includeInNetWorth;
  final bool archived;
  final String dataSource;
  final LocalDate? lastReconciledOn;

  Account copyWith({
    String? name,
    bool? includeInBudget,
    bool? includeInForecast,
    bool? includeInNetWorth,
    bool? archived,
    String? dataSource,
    LocalDate? lastReconciledOn,
  }) => Account(
    id: id,
    name: name ?? this.name,
    type: type,
    includeInBudget: includeInBudget ?? this.includeInBudget,
    includeInForecast: includeInForecast ?? this.includeInForecast,
    includeInNetWorth: includeInNetWorth ?? this.includeInNetWorth,
    archived: archived ?? this.archived,
    dataSource: dataSource ?? this.dataSource,
    lastReconciledOn: lastReconciledOn ?? this.lastReconciledOn,
  );
}

enum CategoryKind {
  income,
  expense;

  LedgerKind get ledgerKind =>
      this == income ? LedgerKind.income : LedgerKind.expense;
}

@immutable
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.archived = false,
  });

  final String id;
  final String name;
  final CategoryKind kind;
  final String? parentId;
  final bool archived;

  Category copyWith({String? name, String? parentId, bool? archived}) =>
      Category(
        id: id,
        name: name ?? this.name,
        kind: kind,
        parentId: parentId ?? this.parentId,
        archived: archived ?? this.archived,
      );
}

/// Ledger accounts the application maintains on the user's behalf. Their
/// identifiers are fixed so every device agrees on them without syncing.
abstract final class SystemAccounts {
  static const openingEquity = 'system:opening-equity';
  static const balanceAdjustments = 'system:balance-adjustments';
  static const transferClearing = 'system:transfer-clearing';
  static const reimbursementReceivable = 'system:reimbursement-receivable';

  static const kinds = <String, LedgerKind>{
    openingEquity: LedgerKind.equity,
    balanceAdjustments: LedgerKind.equity,
    transferClearing: LedgerKind.asset,
    reimbursementReceivable: LedgerKind.asset,
  };
}

/// The user's accounts and categories, mapped onto ledger accounts.
///
/// A user account's ledger account shares its identifier, as does each
/// category, so postings reference user-facing identifiers directly.
@immutable
class Chart {
  Chart({
    required this.currency,
    required Iterable<Account> accounts,
    required Iterable<Category> categories,
  }) : _accounts = {for (final a in accounts) a.id: a},
       _categories = {for (final c in categories) c.id: c};

  final Currency currency;
  final Map<String, Account> _accounts;
  final Map<String, Category> _categories;

  Iterable<Account> get accounts => _accounts.values;
  Iterable<Category> get categories => _categories.values;

  bool hasAccount(String id) => _accounts.containsKey(id);
  bool hasCategory(String id) => _categories.containsKey(id);

  Account account(String id) =>
      _accounts[id] ?? (throw ArgumentError.value(id, 'id', 'unknown account'));

  Category category(String id) =>
      _categories[id] ??
      (throw ArgumentError.value(id, 'id', 'unknown category'));

  /// Ledger kind of any posting target, or null when it is unknown.
  LedgerKind? kindOf(String ledgerAccountId) =>
      _accounts[ledgerAccountId]?.type.ledgerKind ??
      _categories[ledgerAccountId]?.kind.ledgerKind ??
      SystemAccounts.kinds[ledgerAccountId];

  Chart withAccount(Account account) => Chart(
    currency: currency,
    accounts: {..._accounts, account.id: account}.values,
    categories: categories,
  );

  Chart withCategory(Category category) => Chart(
    currency: currency,
    accounts: accounts,
    categories: {..._categories, category.id: category}.values,
  );
}

/// Converts a user-facing signed amount into a ledger delta for [kind].
///
/// For assets a positive amount is money held; for liabilities it is money
/// owed, which the ledger records as a credit (negative).
Money toLedgerSign(LedgerKind kind, Money userAmount) =>
    kind == LedgerKind.liability ? -userAmount : userAmount;
