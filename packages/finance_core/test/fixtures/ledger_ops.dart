import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'ops.dart';

final Map<String, FixtureOp> ledgerOps = {
  'money.parse': _moneyParse,
  'money.allocate': _moneyAllocate,
  'journal.validate': _journalValidate,
  'ledger.scenario': _ledgerScenario,
};

void _moneyParse(Map<String, dynamic> input, Map<String, dynamic> expected) {
  Object result;
  try {
    result = parseMinor(
      input['text'] as String,
      input['exponent'] as int,
      decimalSeparator: input['decimalSeparator'] as String? ?? '.',
    );
  } on FormatException {
    result = 'FORMAT';
  } on MoneyRangeException {
    result = 'OUT_OF_RANGE';
  }
  expect(result, expected['minor'] ?? expected['error']);
}

void _moneyAllocate(Map<String, dynamic> input, Map<String, dynamic> expected) {
  expect(
    allocateByWeights(
      input['total'] as int,
      (input['weights'] as List).cast<int>(),
    ),
    expected['parts'],
  );
}

void _journalValidate(
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
) {
  List<String> codes;
  try {
    final postings = [
      for (final raw
          in (input['postings'] as List).cast<Map<String, dynamic>>())
        Posting(
          raw['account'] as String,
          Money(raw['minor'] as int, Currency(raw['currency'] as String, 2)),
        ),
    ];
    codes = validatePostings(postings).map((e) => e.code).toList();
  } on MoneyRangeException {
    codes = [LedgerError.outOfRange.code];
  }
  expect(codes.toSet(), (expected['errors'] as List).cast<String>().toSet());
}

void _ledgerScenario(
  Map<String, dynamic> input,
  Map<String, dynamic> expected,
) {
  final currency = Currency(
    input['currency'] as String,
    input['exponent'] as int,
  );
  Money money(Object? text) => Money.parse(text as String, currency);

  final chart = Chart(
    currency: currency,
    accounts: [
      for (final raw
          in (input['accounts'] as List).cast<Map<String, dynamic>>())
        Account(
          id: raw['id'] as String,
          name: raw['id'] as String,
          type: AccountType.values.byName(raw['type'] as String),
          includeInNetWorth: raw['includeInNetWorth'] as bool? ?? true,
        ),
    ],
    categories: [
      for (final raw
          in (input['categories'] as List).cast<Map<String, dynamic>>())
        Category(
          id: raw['id'] as String,
          name: raw['id'] as String,
          kind: CategoryKind.values.byName(raw['kind'] as String),
        ),
    ],
  );
  final factory = JournalFactory(chart);
  final journals = <String, Journal>{};
  final refs = <String, String>{};
  final errors = <Map<String, Object>>[];

  Journal build(Map<String, dynamic> entry) => factory.build(
    TransactionDraft(
      type: TransactionType.values.byName(entry['type'] as String),
      accountId: entry['account'] as String,
      counterAccountId: entry['to'] as String?,
      amount: money(entry['amount']),
      effectiveDate: LocalDate.parse(entry['date'] as String),
      status: JournalStatus.values.byName(
        entry['status'] as String? ?? 'posted',
      ),
      refundOf: refs[entry['refundOf']],
      splits: [
        for (final split
            in (entry['splits'] as List? ?? []).cast<Map<String, dynamic>>())
          Split(split['category'] as String, money(split['amount'])),
      ],
    ),
  );

  final entries = (input['entries'] as List).cast<Map<String, dynamic>>();
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    try {
      if (entry['type'] == 'correct') {
        final target = journals[refs[entry['target']]]!;
        final result = correctJournal(
          target,
          build(entry['replacement'] as Map<String, dynamic>),
        );
        for (final journal in result.journals) {
          journals[journal.id] = journal;
        }
        continue;
      }
      final journal = build(entry);
      journals[journal.id] = journal;
      if (entry['ref'] != null) refs[entry['ref'] as String] = journal.id;
    } on DraftException catch (e) {
      errors.add({'entry': index, 'code': e.code.code});
    }
  }

  final ledger = LedgerProjection(chart, journals.values);
  expect(errors, expected['errors'], reason: 'draft errors');
  expect(journals.length, expected['journalCount'], reason: 'journal count');
  (expected['balances'] as Map<String, dynamic>).forEach((id, value) {
    expect(ledger.displayBalance(id), money(value), reason: 'balance $id');
  });
  (expected['pendingBalances'] as Map<String, dynamic>? ?? {}).forEach((
    id,
    value,
  ) {
    expect(
      ledger.displayBalance(id, includePending: true),
      money(value),
      reason: 'pending balance $id',
    );
  });
  expect(ledger.netWorth(), money(expected['netWorth']), reason: 'net worth');

  final periods = (input['periods'] as List).cast<Map<String, dynamic>>();
  final expectedPeriods = (expected['periods'] as List)
      .cast<Map<String, dynamic>>();
  for (var i = 0; i < periods.length; i++) {
    final from = LocalDate.parse(periods[i]['start'] as String);
    final to = LocalDate.parse(periods[i]['end'] as String);
    final want = expectedPeriods[i];
    expect(
      ledger.expenses(from, to),
      money(want['expenses']),
      reason: 'expenses period $i',
    );
    expect(
      ledger.income(from, to),
      money(want['income']),
      reason: 'income period $i',
    );
    if (want['pendingExpenses'] != null) {
      expect(
        ledger.pendingExpenses(from, to),
        money(want['pendingExpenses']),
        reason: 'pending expenses period $i',
      );
    }
  }
  if (periods.isNotEmpty) {
    final from = LocalDate.parse(periods.first['start'] as String);
    final to = LocalDate.parse(periods.first['end'] as String);
    (expected['categories'] as Map<String, dynamic>? ?? {}).forEach((
      id,
      value,
    ) {
      expect(
        ledger.categoryNet(id, from, to),
        money(value),
        reason: 'category $id',
      );
    });
  }
}
