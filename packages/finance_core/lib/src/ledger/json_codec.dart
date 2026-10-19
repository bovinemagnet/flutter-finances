import '../money/money.dart';
import '../time/local_date.dart';
import 'accounts.dart';
import 'journal.dart';

/// JSON formats from `spec/sync/protocol.md`, shared with the server.

Map<String, Object?> journalToJson(Journal journal) => {
  'id': journal.id,
  'type': journal.type.name,
  'status': journal.status.name,
  'effectiveDate': journal.effectiveDate.toString(),
  'enteredAt': journal.enteredAt.toUtc().toIso8601String(),
  'currency': journal.postings.isEmpty
      ? journal.amount?.currency.code
      : journal.postings.first.amount.currency.code,
  'postings': [
    for (final p in journal.postings)
      {'account': p.ledgerAccountId, 'amountMinor': p.amount.minor},
  ],
  'accountId': journal.accountId,
  'counterAccountId': journal.counterAccountId,
  'amountMinor': journal.amount?.minor,
  'payee': journal.payee,
  'notes': journal.notes,
  'tags': (journal.tags.toList()..sort()),
  'refundOf': journal.refundOf,
  'reversalOf': journal.reversalOf,
  'replaces': journal.replaces,
};

/// Reads a journal in the workspace [currency]; a different `currency`
/// field is rejected rather than reinterpreted.
Journal journalFromJson(Map<String, Object?> json, Currency currency) {
  final code = json['currency'] as String?;
  if (code != null && code != currency.code) {
    throw CurrencyMismatchException(
      currency,
      Currency(code, currency.exponent),
    );
  }
  Money money(Object? minor) => Money(minor as int, currency);
  return Journal(
    id: json['id'] as String,
    type: TransactionType.values.byName(json['type'] as String),
    status: JournalStatus.values.byName(json['status'] as String),
    effectiveDate: LocalDate.parse(json['effectiveDate'] as String),
    enteredAt: DateTime.parse(json['enteredAt'] as String).toUtc(),
    postings: [
      for (final p in (json['postings'] as List).cast<Map<String, Object?>>())
        Posting(p['account'] as String, money(p['amountMinor'])),
    ],
    accountId: json['accountId'] as String?,
    counterAccountId: json['counterAccountId'] as String?,
    amount: json['amountMinor'] == null ? null : money(json['amountMinor']),
    payee: json['payee'] as String?,
    notes: json['notes'] as String?,
    tags: {...(json['tags'] as List? ?? const []).cast<String>()},
    refundOf: json['refundOf'] as String?,
    reversalOf: json['reversalOf'] as String?,
    replaces: json['replaces'] as String?,
  );
}

Map<String, Object?> accountToJson(Account account) => {
  'id': account.id,
  'name': account.name,
  'type': account.type.name,
  'includeInBudget': account.includeInBudget,
  'includeInForecast': account.includeInForecast,
  'includeInNetWorth': account.includeInNetWorth,
  'archived': account.archived,
  'dataSource': account.dataSource,
  'lastReconciledOn': account.lastReconciledOn?.toString(),
  'sharing': account.sharing.name,
};

Account accountFromJson(Map<String, Object?> json) => Account(
  id: json['id'] as String,
  name: json['name'] as String,
  type: AccountType.values.byName(json['type'] as String),
  includeInBudget: json['includeInBudget'] as bool? ?? true,
  includeInForecast: json['includeInForecast'] as bool? ?? true,
  includeInNetWorth: json['includeInNetWorth'] as bool? ?? true,
  archived: json['archived'] as bool? ?? false,
  dataSource: json['dataSource'] as String? ?? 'manual',
  lastReconciledOn: json['lastReconciledOn'] == null
      ? null
      : LocalDate.parse(json['lastReconciledOn'] as String),
  sharing: AccountSharing.values.byName(
    json['sharing'] as String? ?? AccountSharing.private.name,
  ),
);

Map<String, Object?> categoryToJson(Category category) => {
  'id': category.id,
  'name': category.name,
  'kind': category.kind.name,
  'parentId': category.parentId,
  'archived': category.archived,
};

Category categoryFromJson(Map<String, Object?> json) => Category(
  id: json['id'] as String,
  name: json['name'] as String,
  kind: CategoryKind.values.byName(json['kind'] as String),
  parentId: json['parentId'] as String?,
  archived: json['archived'] as bool? ?? false,
);
