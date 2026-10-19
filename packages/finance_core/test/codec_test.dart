import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;

  test('journals round-trip through the sync JSON format', () {
    final journal = Journal(
      id: 'j1',
      type: TransactionType.expense,
      status: JournalStatus.posted,
      effectiveDate: LocalDate(2026, 7, 1),
      enteredAt: DateTime.utc(2026, 7, 1, 2, 3, 4),
      postings: [
        Posting('groceries', Money(1000, aud)),
        Posting('bank', Money(-1000, aud)),
      ],
      accountId: 'bank',
      amount: Money(1000, aud),
      payee: 'Grocer',
      tags: {'holiday'},
      refundOf: 'j0',
    );
    final json = journalToJson(journal);
    expect(json['postings'], [
      {'account': 'groceries', 'amountMinor': 1000},
      {'account': 'bank', 'amountMinor': -1000},
    ]);
    expect(json['enteredAt'], '2026-07-01T02:03:04.000Z');
    final back = journalFromJson(json, aud);
    expect(journalToJson(back), json);
  });

  test('accounts and categories round-trip', () {
    final account = Account(
      id: 'a',
      name: 'Visa',
      type: AccountType.creditCard,
      includeInForecast: false,
      lastReconciledOn: LocalDate(2026, 6, 30),
    );
    expect(
      accountToJson(accountFromJson(accountToJson(account))),
      accountToJson(account),
    );
    const category = Category(
      id: 'c',
      name: 'Fuel',
      kind: CategoryKind.expense,
      parentId: 'p',
    );
    expect(
      categoryToJson(categoryFromJson(categoryToJson(category))),
      categoryToJson(category),
    );
  });

  test('commands serialise their envelope', () {
    final command = SyncCommand(
      commandId: 'c1',
      workspaceId: 'w1',
      deviceId: 'd1',
      type: CommandType.entityUpsert,
      entityType: 'account',
      entityId: 'a1',
      baseRevision: 2,
      payload: {
        'fields': {'name': 'Bills'},
      },
    );
    final json = command.toJson();
    expect(json['type'], 'entity.upsert');
    expect(json['schemaVersion'], syncSchemaVersion);
    expect(SyncCommand.fromJson(json).toJson(), json);
  });

  test('accounts carry household sharing, private by default', () {
    const account = Account(
      id: 'a',
      name: 'Joint',
      type: AccountType.transaction,
    );
    expect(account.sharing, AccountSharing.private);
    final shared = account.copyWith(sharing: AccountSharing.shared);
    expect(accountToJson(shared)['sharing'], 'shared');
    expect(
      accountFromJson(accountToJson(shared)).sharing,
      AccountSharing.shared,
    );
    final legacy = accountToJson(account)..remove('sharing');
    expect(accountFromJson(legacy).sharing, AccountSharing.private);
  });
}
