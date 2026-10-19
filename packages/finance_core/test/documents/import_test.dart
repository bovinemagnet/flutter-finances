import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

CsvMapping mapping(String account) => CsvMapping(
  id: 'm-$account',
  name: account,
  accountId: account,
  dateColumn: const CsvColumn.header('Date'),
  descriptionColumn: const CsvColumn.header('Description'),
  amountColumn: const CsvColumn.header('Amount'),
  referenceColumn: const CsvColumn.header('Reference'),
);

Uint8List csv(List<String> rows) => Uint8List.fromList(
  utf8.encode('Date,Description,Amount,Reference\n${rows.join('\n')}\n'),
);

ImportPreview preview(
  Uint8List bytes, {
  String account = 'bank',
  List<ImportBatch> batches = const [],
  List<SourceRecord> records = const [],
  List<Journal> journals = const [],
  Set<String> receiptJournalIds = const {},
}) => previewImport(
  accountId: account,
  parsed: parseCsvBytes(bytes, mapping(account), aud),
  sourceHash: sourceHashOf(bytes),
  chart: testChart,
  batches: batches,
  existingRecords: records,
  journals: journals,
  receiptJournalIds: receiptJournalIds,
);

ImportCommit commit(
  ImportPreview preview, {
  Map<int, RowDecision> decisions = const {},
  String batchId = 'b1',
}) => commitImport(
  preview: preview,
  chart: testChart,
  batchId: batchId,
  importedAt: DateTime.utc(2026, 7, 10),
  uncategorisedExpenseId: 'uncategorised',
  uncategorisedIncomeId: 'other-income',
  decisions: decisions,
);

List<Journal> post(ImportCommit commit) => [
  for (final draft in commit.drafts) JournalFactory(testChart).build(draft),
];

void main() {
  final statement = csv([
    '01/07/2026,WOOLWORTHS 1234 SYDNEY,-63.25,',
    '01/07/2026,COFFEE CART,-4.50,',
    '01/07/2026,COFFEE CART,-4.50,',
    '02/07/2026,SALARY ACME PTY LTD,2500.00,PAY-1',
    'bad,row,1.00,',
  ]);

  group('preview (IMP 01, IMP 03)', () {
    test('shows totals and row errors before commit', () {
      final p = preview(statement);
      expect(p.errors.single.row, 6);
      expect(p.rows.length, 4);
      expect(p.totals.count, 4);
      expect(p.totals.credits, m('2500.00'));
      expect(p.totals.debits, m('72.25'));
      expect(p.totals.net, m('2427.75'));
      expect(
        p.rows.every((r) => r.status == PreviewRowStatus.newEntry),
        isTrue,
      );
      expect(p.alreadyImportedBatch, isNull);
    });

    test('A11: identical same-day purchases are both kept', () {
      final p = preview(statement);
      final coffees = p.rows
          .where((r) => r.row.description == 'COFFEE CART')
          .toList();
      expect(coffees.map((r) => r.fingerprint).toSet().length, 2);
      final result = commit(p);
      expect(result.drafts.where((d) => d.payee == 'COFFEE CART').length, 2);
    });

    test('statement balances are compared, never forced', () {
      final p = preview(statement);
      final check = p.checkStatementBalance(
        opening: m('100.00'),
        closing: m('2600.00'),
      );
      expect(check.importedNet, m('2427.75'));
      expect(check.difference, m('72.25'));
      expect(check.balanced, isFalse);
    });

    test('flags gaps in dates within the file and since the last import', () {
      final p = previewImport(
        accountId: 'bank',
        parsed: parseCsvBytes(
          csv([
            '01/07/2026,A,-1.00,',
            '02/07/2026,B,-1.00,',
            '20/07/2026,C,-1.00,',
          ]),
          mapping('bank'),
          aud,
        ),
        sourceHash: 'h',
        chart: testChart,
        existingRecords: [
          SourceRecord(
            id: 's0',
            batchId: 'b0',
            accountId: 'bank',
            rowNumber: 2,
            fingerprint: 'x#1',
            raw: const [],
            date: d('2026-06-01'),
            amount: m('-1.00'),
            description: 'old',
            decision: SourceDecision.created,
          ),
        ],
      );
      expect(p.dateGaps.map((g) => (g.from, g.to)).toList(), [
        (d('2026-06-01'), d('2026-07-01')),
        (d('2026-07-02'), d('2026-07-20')),
      ]);
    });

    test('detects possible transfers and card repayments', () {
      final savingsSide = JournalFactory(testChart).build(
        TransactionDraft(
          id: 'income-on-savings',
          type: TransactionType.income,
          accountId: 'savings',
          amount: m('500.00'),
          effectiveDate: d('2026-07-03'),
          splits: [Split('other-income', m('500.00'))],
        ),
      );
      final p = preview(
        csv([
          '03/07/2026,INTERNET BANKING,-500.00,',
          '04/07/2026,TRANSFER TO SAVINGS,-50.00,',
          '05/07/2026,COMMBANK VISA PAYMENT,-120.00,',
        ]),
        journals: [savingsSide],
      );
      expect(p.rows[0].flags, contains(PreviewFlag.possibleTransfer));
      expect(p.rows[0].transferCounterpart?.id, 'income-on-savings');
      expect(p.rows[1].flags, contains(PreviewFlag.possibleTransfer));
      expect(p.rows[2].flags, contains(PreviewFlag.possibleCardRepayment));
      expect(p.rows.every((r) => r.requiresDecision), isTrue);

      final card = preview(
        csv(['06/07/2026,PAYMENT THANK YOU,120.00,']),
        account: 'card',
      );
      expect(
        card.rows.single.flags,
        contains(PreviewFlag.possibleCardRepayment),
      );
    });
  });

  group('repeatability (IMP 02, A12)', () {
    test('A12: re-importing the same committed batch creates no journals', () {
      final first = commit(preview(statement));
      expect(first.drafts.length, 4);
      expect(first.batch.sourceHash, sourceHashOf(statement));
      expect(first.sourceRecords.length, 4);
      expect(first.sourceRecords.every((r) => r.raw.isNotEmpty), isTrue);

      final again = preview(
        statement,
        batches: [first.batch],
        records: first.sourceRecords,
      );
      expect(again.alreadyImportedBatch?.id, 'b1');
      expect(
        again.rows.every((r) => r.status == PreviewRowStatus.duplicate),
        isTrue,
      );
      final second = commit(again, batchId: 'b2');
      expect(second.drafts, isEmpty);
      expect(second.alreadyCommitted, isTrue);
      expect(second.batch.id, 'b1');
    });

    test('a re-exported file with the same rows is recognised row by row', () {
      final first = commit(preview(statement));
      final reexported = csv([
        '01/07/2026,WOOLWORTHS 1234 SYDNEY,-63.25,',
        '01/07/2026,COFFEE CART,-4.50,',
        '01/07/2026,COFFEE CART,-4.50,',
        '02/07/2026,SALARY ACME PTY LTD,2500.00,PAY-1',
      ]);
      final p = preview(
        reexported,
        batches: [first.batch],
        records: first.sourceRecords,
      );
      expect(p.alreadyImportedBatch, isNull);
      expect(
        p.rows.every((r) => r.status == PreviewRowStatus.duplicate),
        isTrue,
      );
      final second = commit(p, batchId: 'b2');
      expect(second.drafts, isEmpty);
      expect(
        second.sourceRecords.every(
          (r) => r.decision == SourceDecision.duplicate,
        ),
        isTrue,
      );
      expect(
        second.sourceRecords.first.journalId,
        first.sourceRecords.first.journalId,
      );
    });

    test('an overlapping statement presents ambiguous rows for review', () {
      final first = commit(preview(csv(['01/07/2026,COFFEE CART,-4.50,'])));
      final overlap = preview(
        csv([
          '01/07/2026,COFFEE CART,-4.50,',
          '01/07/2026,COFFEE CART,-4.50,',
          '02/07/2026,Coffee Cart.,-4.50,',
        ]),
        batches: [first.batch],
        records: first.sourceRecords,
      );
      expect(overlap.rows.map((r) => r.status).toList(), [
        PreviewRowStatus.duplicate,
        PreviewRowStatus.ambiguous,
        PreviewRowStatus.newEntry,
      ]);
      expect(
        () => commit(overlap, batchId: 'b2'),
        throwsA(
          isA<ImportCommitException>().having((e) => e.rows, 'rows', [3]),
        ),
      );
      final resolved = commit(
        overlap,
        batchId: 'b2',
        decisions: {3: const CreateEntry()},
      );
      expect(resolved.drafts.length, 2);
    });

    test('a description changed between exports is ambiguous, not new', () {
      final first = commit(
        preview(csv(['01/07/2026,PENDING WOOLWORTHS,-63.25,'])),
      );
      final p = preview(
        csv(['01/07/2026,WOOLWORTHS 1234 SYDNEY,-63.25,']),
        batches: [first.batch],
        records: first.sourceRecords,
      );
      expect(p.rows.single.status, PreviewRowStatus.ambiguous);
    });
  });

  group('commit (IMP 01, MATCH 03)', () {
    test('produces drafts and provenance kept separate from journals', () {
      final result = commit(preview(statement));
      final journals = post(result);
      for (final journal in journals) {
        expect(validatePostings(journal.postings), isEmpty);
      }
      final groceries = result.drafts.firstWhere(
        (d) => d.payee!.startsWith('WOOLWORTHS'),
      );
      expect(groceries.type, TransactionType.expense);
      expect(groceries.splits.single.categoryId, 'uncategorised');
      final salary = result.drafts.firstWhere(
        (d) => d.payee!.startsWith('SALARY'),
      );
      expect(salary.type, TransactionType.income);
      final record = result.sourceRecords.firstWhere(
        (r) => r.reference == 'PAY-1',
      );
      expect(record.journalId, salary.id);
      expect(record.decision, SourceDecision.created);
      expect(record.batchId, 'b1');
    });

    test('a category chooser and explicit categories are honoured', () {
      final result = commitImport(
        preview: preview(statement),
        chart: testChart,
        batchId: 'b1',
        importedAt: DateTime.utc(2026, 7, 10),
        uncategorisedExpenseId: 'uncategorised',
        uncategorisedIncomeId: 'other-income',
        chooseCategory: (row) =>
            row.description.startsWith('WOOL') ? 'groceries' : null,
        decisions: {3: const CreateEntry(categoryId: 'dining')},
      );
      expect(
        result.drafts
            .firstWhere((d) => d.payee!.startsWith('WOOL'))
            .splits
            .single
            .categoryId,
        'groceries',
      );
      expect(
        result.drafts
            .firstWhere((d) => d.payee == 'COFFEE CART')
            .splits
            .single
            .categoryId,
        'dining',
      );
    });

    test(
      'A08: confirming a receipt match enriches provenance, adds nothing',
      () {
        final receiptJournal = expense(
          'j-receipt',
          '63.25',
          '2026-07-01',
          account: 'card',
          payee: 'Woolworths',
        );
        final p = preview(
          csv(['02/07/2026,WOOLWORTHS 1234 SYDNEY,-63.25,TX9']),
          account: 'card',
          journals: [receiptJournal],
          receiptJournalIds: {'j-receipt'},
        );
        final row = p.rows.single;
        expect(row.status, PreviewRowStatus.existingMatch);
        expect(row.flags, contains(PreviewFlag.receiptEntry));
        expect(row.proposals.single.journal.id, 'j-receipt');
        expect(() => commit(p), throwsA(isA<ImportCommitException>()));
        final result = commit(
          p,
          decisions: {2: const MatchExisting('j-receipt')},
        );
        expect(result.drafts, isEmpty);
        final record = result.sourceRecords.single;
        expect(record.decision, SourceDecision.matchedExisting);
        expect(record.journalId, 'j-receipt');
        expect(record.reference, 'TX9');
        final ledger = LedgerProjection(testChart, [
          receiptJournal,
          ...post(result),
        ]);
        expect(ledger.expenses(d('2026-07-01'), d('2026-07-31')), m('63.25'));
      },
    );

    test('a match must be one of the proposals', () {
      final p = preview(csv(['02/07/2026,X,-1.00,']));
      expect(
        () => commit(p, decisions: {2: const MatchExisting('nope')}),
        throwsA(isA<ImportCommitException>()),
      );
    });

    test('confirmed transfers become balanced transfer drafts', () {
      final p = preview(csv(['04/07/2026,TRANSFER TO SAVINGS,-50.00,']));
      final result = commit(p, decisions: {2: const CreateTransfer('savings')});
      final draft = result.drafts.single;
      expect(draft.type, TransactionType.transfer);
      expect(draft.accountId, 'bank');
      expect(draft.counterAccountId, 'savings');
      final ledger = LedgerProjection(testChart, post(result));
      expect(ledger.displayBalance('savings'), m('50.00'));
      expect(ledger.expenses(d('2026-07-01'), d('2026-07-31')), m('0.00'));
    });

    test('positive card rows become refunds and skips keep evidence', () {
      final p = preview(
        csv(['06/07/2026,STORE REFUND,25.00,', '07/07/2026,X,-1.00,']),
        account: 'card',
      );
      final result = commit(p, decisions: {3: const SkipRow()});
      expect(result.drafts.single.type, TransactionType.refund);
      expect(result.sourceRecords.last.decision, SourceDecision.skipped);
    });
  });

  group('rollback (IMP 02)', () {
    test('voids untouched journals and flags edited or linked ones', () {
      final result = commit(
        preview(
          csv([
            '01/07/2026,A,-10.00,',
            '02/07/2026,B,-20.00,',
            '03/07/2026,C,-30.00,',
          ]),
        ),
      );
      final journals = post(result);
      final edited = correctJournal(
        journals[1],
        JournalFactory(testChart).build(
          TransactionDraft(
            type: TransactionType.expense,
            accountId: 'bank',
            amount: m('20.00'),
            effectiveDate: d('2026-07-02'),
            splits: [Split('dining', m('20.00'))],
          ),
        ),
      );
      final current = [journals[0], ...edited.journals, journals[2]];
      final links = [
        ReceiptTransactionLink(
          id: 'l1',
          receiptId: 'r1',
          journalId: journals[2].id,
          allocated: m('30.00'),
          confirmedAt: DateTime.utc(2026, 7, 4),
        ),
      ];
      final plan = planRollback(
        batch: result.batch,
        sourceRecords: result.sourceRecords,
        journals: current,
        links: links,
        chart: testChart,
        now: DateTime.utc(2026, 7, 11),
      );
      expect(plan.batch.status, ImportBatchStatus.rolledBack);
      expect(plan.corrections.single.original.id, journals[0].id);
      expect(plan.corrections.single.replacement, isNull);
      expect(plan.issues.map((i) => (i.journalId, i.kind)).toSet(), {
        (journals[1].id, RollbackIssueKind.editedAfterImport),
        (journals[2].id, RollbackIssueKind.linkedToReceipt),
      });
      expect(
        plan.issues
            .firstWhere((i) => i.kind == RollbackIssueKind.editedAfterImport)
            .currentJournalId,
        edited.replacement!.id,
      );
      expect(plan.sourceRecords.every((r) => r.rolledBack), isTrue);

      final explicit = planRollback(
        batch: result.batch,
        sourceRecords: result.sourceRecords,
        journals: current,
        links: links,
        chart: testChart,
        now: DateTime.utc(2026, 7, 11),
        include: {journals[2].id, journals[1].id},
      );
      expect(explicit.corrections.map((c) => c.original.id).toSet(), {
        journals[0].id,
        edited.replacement!.id,
        journals[2].id,
      });
      expect(explicit.linkIdsToRemove, {'l1'});
      expect(explicit.issues, isEmpty);
      final after = LedgerProjection(testChart, [
        ...current.where(
          (j) => !explicit.corrections.any((c) => c.original.id == j.id),
        ),
        for (final c in explicit.corrections) ...c.journals,
      ]);
      expect(after.displayBalance('bank'), m('0.00'));
    });

    test('reconciled journals and matched records are handled explicitly', () {
      final receiptJournal = expense(
        'j-receipt',
        '63.25',
        '2026-07-01',
        account: 'card',
      );
      final matched = commit(
        preview(
          csv(['02/07/2026,WOOLWORTHS,-63.25,']),
          account: 'card',
          journals: [receiptJournal],
          receiptJournalIds: {'j-receipt'},
        ),
        decisions: {2: const MatchExisting('j-receipt')},
      );
      final reconciledChart = testChart.withAccount(
        testChart.account('card').copyWith(lastReconciledOn: d('2026-07-31')),
      );
      final plan = planRollback(
        batch: matched.batch,
        sourceRecords: matched.sourceRecords,
        journals: [receiptJournal],
        links: const [],
        chart: reconciledChart,
        now: DateTime.utc(2026, 7, 11),
      );
      expect(plan.corrections, isEmpty);
      expect(plan.sourceRecords.single.rolledBack, isTrue);

      final created = commit(preview(csv(['01/07/2026,A,-10.00,'])));
      final reconciled = planRollback(
        batch: created.batch,
        sourceRecords: created.sourceRecords,
        journals: post(created),
        links: const [],
        chart: testChart.withAccount(
          testChart.account('bank').copyWith(lastReconciledOn: d('2026-07-31')),
        ),
        now: DateTime.utc(2026, 7, 11),
      );
      expect(reconciled.issues.single.kind, RollbackIssueKind.reconciled);
      expect(reconciled.corrections, isEmpty);
    });
  });

  test('handles 50,000 rows: parse and preview in about two seconds', () {
    final buffer = StringBuffer('Date,Description,Amount,Reference\n');
    for (var i = 0; i < 50000; i++) {
      final day = 1 + i % 28;
      final month = 1 + (i ~/ 28) % 12;
      buffer.write(
        '${day.toString().padLeft(2, '0')}/${month.toString().padLeft(2, '0')}/2026,'
        '"MERCHANT ${i % 500}, SYDNEY",-${1 + i % 300}.${(i % 100).toString().padLeft(2, '0')},\n',
      );
    }
    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final journals = [
      for (var i = 0; i < 2000; i++)
        expense(
          'j$i',
          '${1 + i % 300}.00',
          '2026-0${1 + i % 9}-1${i % 9}',
          account: i.isEven ? 'bank' : 'savings',
        ),
    ];
    final watch = Stopwatch()..start();
    final parsed = parseCsvBytes(bytes, mapping('bank'), aud);
    final p = previewImport(
      accountId: 'bank',
      parsed: parsed,
      sourceHash: sourceHashOf(bytes),
      chart: testChart,
      journals: journals,
    );
    watch.stop();
    expect(parsed.rows.length, 50000);
    expect(p.rows.length, 50000);
    print(
      'Parsed and previewed 50,000 rows in ${watch.elapsedMilliseconds} ms',
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });
}
