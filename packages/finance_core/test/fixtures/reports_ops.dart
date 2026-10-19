import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'ops.dart';

/// Fixture operations for ledger reports (`spec/fixtures/reports.json`).
/// The Java server runs the same cases, so server reports use exactly the
/// client's definitions (REP 01, REP 04).
final Map<String, FixtureOp> reportsOps = {'report.compute': _reportCompute};

void _reportCompute(Map<String, dynamic> input, Map<String, dynamic> expected) {
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
  final refOfId = <String, String>{};

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
      payee: entry['payee'] as String?,
      refundOf: refs[entry['refundOf']],
      splits: [
        for (final split
            in (entry['splits'] as List? ?? []).cast<Map<String, dynamic>>())
          Split(split['category'] as String, money(split['amount'])),
      ],
    ),
  );

  for (final entry in (input['entries'] as List).cast<Map<String, dynamic>>()) {
    if (entry['type'] == 'correct') {
      final target = journals[refs[entry['target']]]!;
      final result = correctJournal(
        target,
        build(entry['replacement'] as Map<String, dynamic>),
      );
      for (final journal in result.journals) {
        journals[journal.id] = journal;
      }
      refOfId[result.reversal.id] = entry['reversalRef'] as String;
      refOfId[result.replacement!.id] = entry['ref'] as String;
      continue;
    }
    final journal = build(entry);
    journals[journal.id] = journal;
    refs[entry['ref'] as String] = journal.id;
    refOfId[journal.id] = entry['ref'] as String;
  }

  final ledger = LedgerProjection(chart, journals.values);
  final report = _compute(ledger, input['report'] as Map<String, dynamic>);
  final wantRows = (expected['rows'] as List).cast<Map<String, dynamic>>();
  expect(
    [for (final row in report.rows) row.key],
    [for (final row in wantRows) row['key']],
    reason: 'row keys',
  );
  for (var i = 0; i < wantRows.length; i++) {
    final want = wantRows[i];
    final row = report.rows[i];
    if (want['label'] != null) {
      expect(row.label, want['label'], reason: 'label ${row.key}');
    }
    expect(
      {for (final e in row.amounts.entries) e.key: e.value.toDecimalString()},
      want['amounts'],
      reason: 'amounts ${row.key}',
    );
    expect(
      [for (final id in row.journalIds) refOfId[id]],
      want['journals'],
      reason: 'journals ${row.key}',
    );
  }
}

Report _compute(LedgerProjection ledger, Map<String, dynamic> spec) {
  final kind = spec['kind'] as String;
  if (kind == 'account-balances') {
    final asOf = spec['asOf'] as String?;
    return accountBalances(
      ledger,
      asOf: asOf == null ? null : LocalDate.parse(asOf),
    );
  }
  final range = _range(spec['period'] as Map<String, dynamic>);
  return switch (kind) {
    'income-vs-expenses' => incomeVsExpenses(ledger, range),
    'spending-by-category' => spendingByCategory(ledger, range),
    'spending-by-payee' => spendingByPayee(ledger, range),
    'net-worth-history' => netWorthHistory(ledger, range),
    'cash-flow' => cashFlow(
      ledger,
      range,
      accountIds: (spec['accounts'] as List).cast<String>().toSet(),
    ),
    _ => fail('Unknown report kind $kind'),
  };
}

DateRange _range(Map<String, dynamic> period) => switch (period['type']) {
  'calendarYear' => DateRange.calendarYear(period['year'] as int),
  'financialYear' => DateRange.financialYear(period['startYear'] as int),
  'custom' => DateRange(
    LocalDate.parse(period['start'] as String),
    LocalDate.parse(period['end'] as String),
  ),
  _ => fail('Unknown period $period'),
};
