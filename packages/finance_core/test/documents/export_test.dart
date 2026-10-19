import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

void main() {
  group('transaction CSV export (EXP 01)', () {
    final split = JournalFactory(testChart).build(
      TransactionDraft(
        id: 'split',
        type: TransactionType.expense,
        accountId: 'card',
        amount: m('30.00'),
        effectiveDate: d('2026-07-04'),
        splits: [Split('groceries', m('20.00')), Split('dining', m('10.00'))],
        payee: '=HYPERLINK("http://evil")',
        notes: '@notes',
        tags: {'b', 'a'},
        enteredAt: DateTime.utc(2026, 7, 4),
      ),
    );
    final transfer = JournalFactory(testChart).build(
      TransactionDraft(
        id: 'transfer',
        type: TransactionType.transfer,
        accountId: 'bank',
        counterAccountId: 'savings',
        amount: m('500.00'),
        effectiveDate: d('2026-07-02'),
        enteredAt: DateTime.utc(2026, 7, 2),
      ),
    );
    final salary = JournalFactory(testChart).build(
      TransactionDraft(
        id: 'salary',
        type: TransactionType.income,
        accountId: 'bank',
        amount: m('2500.00'),
        effectiveDate: d('2026-07-01'),
        splits: [Split('salary', m('2500.00'))],
        payee: '-Employer',
        enteredAt: DateTime.utc(2026, 7, 1),
      ),
    );
    final pending = expense(
      'pending',
      '9.00',
      '2026-07-05',
      status: JournalStatus.pending,
    );
    final corrected = correctJournal(
      expense('old', '1.00', '2026-07-03'),
      null,
    );
    final journals = [split, transfer, salary, pending, ...corrected.journals];

    test(
      'writes one row per category or account line, sanitising text only',
      () {
        final csv = exportTransactionsCsv(journals, testChart);
        final rows = readCsv(csv).records.map((r) => r.fields).toList();
        expect(rows.first, [
          'Date',
          'Account',
          'Payee',
          'Category',
          'Amount',
          'Currency',
          'Type',
          'Status',
          'Notes',
          'Tags',
          'Journal ID',
        ]);
        expect(rows.sublist(1).map((r) => (r[0], r[1], r[3], r[4])).toList(), [
          ('2026-07-01', 'Everyday', 'Salary', '2500.00'),
          ('2026-07-02', 'Everyday', '', '-500.00'),
          ('2026-07-02', 'Savings', '', '500.00'),
          ('2026-07-04', 'Visa', 'Groceries', '-20.00'),
          ('2026-07-04', 'Visa', 'Dining', '-10.00'),
        ]);
        final splitRow = rows.firstWhere((r) => r[3] == 'Groceries');
        expect(splitRow[2], "'=HYPERLINK(\"http://evil\")");
        expect(splitRow[8], "'@notes");
        expect(splitRow[9], 'a; b');
        expect(rows.firstWhere((r) => r[3] == 'Salary')[2], "'-Employer");
        expect(csv, contains('\r\n'));
      },
    );

    test('filters by date, account, pending and corrections', () {
      String ids(TransactionExportFilter filter) =>
          readCsv(exportTransactionsCsv(journals, testChart, filter: filter))
              .records
              .skip(1)
              .map((r) => r.fields.last)
              .toSet()
              .join(',');
      expect(ids(TransactionExportFilter(from: d('2026-07-03'))), 'split');
      expect(
        ids(const TransactionExportFilter(accountIds: {'savings'})),
        'transfer',
      );
      expect(
        ids(const TransactionExportFilter(includePending: true)),
        contains('pending'),
      );
      final withCorrections = ids(
        const TransactionExportFilter(includeCorrections: true),
      );
      expect(withCorrections, contains('old'));
      expect(withCorrections, contains(corrected.reversal.id));
    });

    test('report rows keep numbers numeric and sanitise text', () {
      final csv = exportReportCsv(
        ['Category', 'Spent', 'Count', 'From'],
        [
          ['=cmd', m('-12.50'), 3, d('2026-07-01')],
          [null, m('0.00'), -1, true],
        ],
      );
      expect(
        csv,
        'Category,Spent,Count,From\r\n\'=cmd,-12.50,3,2026-07-01\r\n,0.00,-1,true\r\n',
      );
    });
  });

  group('archive manifest (DATA 01)', () {
    final journal = expense('j1', '63.25', '2026-07-01', payee: 'Grocer');
    final dataBytes = utf8.encode(jsonEncode([journalToJson(journal)]));
    final imageBytes = [0xFF, 0xD8, 0xFF, 1, 2, 3];
    final receipt = Receipt(
      id: 'r1',
      capturedAt: DateTime.utc(2026, 7, 1),
      source: CaptureSource.camera,
    );
    final asset = DocumentAsset(
      id: 'a1',
      receiptId: 'r1',
      kind: AssetKind.source,
      contentType: DocumentContentType.jpeg,
      sha256: sha256Hex(imageBytes),
      sizeBytes: imageBytes.length,
      pageCount: 1,
      createdAt: DateTime.utc(2026, 7, 1),
    );
    final link = ReceiptTransactionLink(
      id: 'l1',
      receiptId: 'r1',
      journalId: 'j1',
      allocated: m('63.25'),
      confirmedAt: DateTime.utc(2026, 7, 1),
    );

    ArchiveManifest manifest({int schemaVersion = archiveSchemaVersion}) =>
        ArchiveManifest(
          schemaVersion: schemaVersion,
          createdAt: DateTime.utc(2026, 7, 9),
          workspaceId: 'w1',
          currency: aud,
          timezone: 'Australia/Sydney',
          acceptedRevision: 42,
          pendingLocalChanges: const [
            PendingLocalChange(
              commandId: 'c1',
              type: 'entity.upsert',
              entityType: 'receipt',
              entityId: 'r2',
            ),
          ],
          files: [
            ArchiveFile.fromBytes(
              'data/journals.json',
              dataBytes,
              ArchiveFileRole.data,
              contentType: 'application/json',
            ),
            ArchiveFile.fromBytes(
              'receipts/r1/a1.jpg',
              imageBytes,
              ArchiveFileRole.receiptSource,
              contentType: 'image/jpeg',
              assetId: 'a1',
            ),
          ],
          entityCounts: const {
            'journals': 1,
            'receipts': 1,
            'documentAssets': 1,
            'receiptLinks': 1,
          },
          relationships: archiveRelationships([receipt], [asset], [link]),
        );

    final files = {
      'data/journals.json': dataBytes,
      'receipts/r1/a1.jpg': imageBytes,
    };
    const counts = {
      'journals': 1,
      'receipts': 1,
      'documentAssets': 1,
      'receiptLinks': 1,
    };

    test('records versions, semantics, hashes, counts and relationships', () {
      final json = archiveManifestToJson(manifest());
      expect(json['formatVersion'], archiveFormatVersion);
      expect(json['schemaVersion'], 1);
      expect(json['currency'], 'AUD');
      expect(json['currencyExponent'], 2);
      expect(json['timezone'], 'Australia/Sydney');
      expect(json['effectiveDateSemantics'], contains('YYYY-MM-DD'));
      expect(json['acceptedRevision'], 42);
      expect(
        (json['pendingLocalChanges'] as List).single,
        containsPair('commandId', 'c1'),
      );
      final file = (json['files'] as List).last as Map;
      expect(file['sha256'], sha256Hex(imageBytes));
      expect(file['sizeBytes'], 6);
      expect(json['relationships'], [
        {
          'receiptId': 'r1',
          'assetIds': ['a1'],
          'journalIds': ['j1'],
        },
      ]);
      final back = archiveManifestFromJson(
        (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>(),
      );
      expect(archiveManifestToJson(back), json);
    });

    test('A16: a complete archive verifies cleanly into a preview', () {
      final preview = verifyArchive(
        manifest: manifest(),
        files: files,
        journals: [journal],
        actualCounts: counts,
      );
      expect(preview.issues, isEmpty);
      expect(preview.canRestore, isTrue);
      expect(preview.pendingLocalChanges, 1);
      expect(preview.counts['journals'], (expected: 1, actual: 1));
    });

    test('detects tampered, missing and unexpected files', () {
      final tampered = verifyArchive(
        manifest: manifest(),
        files: {
          ...files,
          'receipts/r1/a1.jpg': [0xFF, 0xD8, 0xFF, 9, 9, 9],
          'extra.txt': [1],
        },
        journals: [journal],
        actualCounts: counts,
      );
      expect(
        tampered.issues.map((i) => i.code),
        containsAll([
          RestoreIssueCode.hashMismatch,
          RestoreIssueCode.unexpectedFile,
        ]),
      );
      expect(tampered.canRestore, isFalse);

      final missing = verifyArchive(
        manifest: manifest(),
        files: {'data/journals.json': dataBytes},
        journals: [journal],
        actualCounts: counts,
      );
      expect(
        missing.issues.map((i) => i.code),
        containsAll([
          RestoreIssueCode.missingFile,
          RestoreIssueCode.missingAsset,
        ]),
      );
    });

    test('checks schema compatibility, balanced journals and counts', () {
      final tooNew = verifyArchive(
        manifest: manifest(schemaVersion: 99),
        files: files,
        journals: [journal],
        actualCounts: counts,
      );
      expect(
        tooNew.issues.map((i) => i.code),
        contains(RestoreIssueCode.schemaUnsupported),
      );

      final unbalanced = Journal(
        id: 'bad',
        type: TransactionType.expense,
        status: JournalStatus.posted,
        effectiveDate: d('2026-07-01'),
        enteredAt: DateTime.utc(2026, 7, 1),
        postings: [
          Posting('groceries', m('80.00')),
          Posting('bank', m('-23.46')),
        ],
      );
      final broken = verifyArchive(
        manifest: manifest(),
        files: files,
        journals: [journal, unbalanced],
        actualCounts: {...counts, 'journals': 2},
      );
      final codes = broken.issues.map((i) => i.code);
      expect(
        codes,
        containsAll([
          RestoreIssueCode.unbalancedJournal,
          RestoreIssueCode.countMismatch,
        ]),
      );
      expect(
        broken.issues
            .firstWhere((i) => i.code == RestoreIssueCode.unbalancedJournal)
            .subject,
        'bad',
      );

      final dangling = verifyArchive(
        manifest: manifest(),
        files: files,
        journals: const [],
        actualCounts: {...counts, 'journals': 0},
      );
      expect(
        dangling.issues.map((i) => i.code),
        contains(RestoreIssueCode.danglingRelationship),
      );
    });
  });
}
