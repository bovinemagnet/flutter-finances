import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

void main() {
  group('candidate ranking (MATCH 01)', () {
    final journals = [
      expense('exact-far', '63.25', '2026-07-04', payee: 'Unrelated Pty Ltd'),
      expense(
        'exact-near',
        '63.25',
        '2026-07-02',
        payee: 'WOOLWORTHS 1234 SYDNEY',
      ),
      expense(
        'exact-card',
        '63.25',
        '2026-07-03',
        account: 'card',
        payee: 'Woolworths',
      ),
      expense('close-amount', '60.00', '2026-07-01', payee: 'Woolworths Metro'),
      expense('outside-window', '63.25', '2026-07-08', payee: 'Woolworths'),
      expense(
        'draft',
        '63.25',
        '2026-07-01',
        payee: 'Woolworths',
        status: JournalStatus.draft,
      ),
      expense('unrelated', '12.00', '2026-07-01', payee: 'Cafe'),
    ];
    final fields = ReceiptFields(
      merchant: 'Woolworths Metro',
      date: d('2026-07-01'),
      total: m('63.25'),
    );

    test('exact amounts first, then merchant, account hint and date', () {
      final ranked = rankMatchCandidates(fields, journals, accountHint: 'card');
      expect(ranked.map((c) => c.journal.id).toList(), [
        'exact-card',
        'exact-near',
        'exact-far',
        'close-amount',
      ]);
      expect(ranked.first.linkable, isTrue);
      expect(ranked.last.linkable, isFalse);
    });

    test('each candidate explains itself in plain words', () {
      final ranked = rankMatchCandidates(fields, journals, accountHint: 'card');
      final best = ranked.first;
      expect(
        best.reasons.map((r) => r.code),
        containsAll([
          MatchReasonCode.sameAmount,
          MatchReasonCode.merchantSimilar,
          MatchReasonCode.accountHint,
          MatchReasonCode.dateNear,
        ]),
      );
      expect(
        best.reasons.map((r) => r.message).join(' | '),
        contains('2 days after'),
      );
      final mismatch = ranked.last;
      expect(
        mismatch.reasons.map((r) => r.code),
        contains(MatchReasonCode.amountMismatch),
      );
    });

    test('the date window is configurable', () {
      final wide = rankMatchCandidates(
        fields,
        journals,
        settings: const MatchSettings(dateWindowDays: 7),
      );
      expect(wide.map((c) => c.journal.id), contains('outside-window'));
    });

    test('a currency mismatch prevents linking', () {
      final usd = ReceiptFields(
        merchant: 'Woolworths',
        date: d('2026-07-01'),
        total: Money(6325, const Currency('USD', 2)),
      );
      final ranked = rankMatchCandidates(usd, journals);
      expect(ranked, isNotEmpty);
      expect(ranked.every((c) => !c.linkable), isTrue);
      expect(
        ranked.first.reasons.map((r) => r.code),
        contains(MatchReasonCode.currencyMismatch),
      );
    });

    test('confirmation is always explicit and refuses mismatches', () {
      final ranked = rankMatchCandidates(fields, journals);
      final link = confirmMatch(
        ranked.first,
        receiptId: 'r1',
        receiptTotal: m('63.25'),
        existingLinks: const [],
        confirmedAt: DateTime.utc(2026, 7, 5),
      );
      expect(link.journalId, ranked.first.journal.id);
      expect(link.allocated, m('63.25'));
      expect(
        () => confirmMatch(
          ranked.last,
          receiptId: 'r1',
          receiptTotal: m('63.25'),
          existingLinks: const [],
          confirmedAt: DateTime.utc(2026, 7, 5),
        ),
        throwsA(isA<LinkException>()),
      );
    });

    test('fully linked entries are not linkable again', () {
      final links = [
        ReceiptTransactionLink(
          id: 'l',
          receiptId: 'other',
          journalId: 'exact-near',
          allocated: m('63.25'),
          confirmedAt: DateTime.utc(2026, 7, 2),
        ),
      ];
      final ranked = rankMatchCandidates(
        fields,
        journals,
        existingLinks: links,
      );
      final near = ranked.firstWhere((c) => c.journal.id == 'exact-near');
      expect(near.linkable, isFalse);
      expect(
        near.reasons.map((r) => r.code),
        contains(MatchReasonCode.alreadyLinked),
      );
    });
  });

  group('deduplication (MATCH 02)', () {
    DocumentAsset asset(String id, String receiptId, String sha) =>
        DocumentAsset(
          id: id,
          receiptId: receiptId,
          kind: AssetKind.source,
          contentType: DocumentContentType.jpeg,
          sha256: sha,
          sizeBytes: 10,
          pageCount: 1,
          createdAt: DateTime.utc(2026, 7, 1),
        );

    test('identical files are found by SHA-256 and only warned about', () {
      final existing = [
        asset('a1', 'r1', 'aa' * 32),
        asset('a2', 'r2', 'bb' * 32),
      ];
      final warnings = findIdenticalFiles(
        asset('a3', 'r3', 'AA' * 32),
        existing,
      );
      expect(warnings.single.kind, DuplicateKind.identicalFile);
      expect(warnings.single.otherReceiptId, 'r1');
      expect(
        sha256Hex([1, 2, 3]),
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
      );
    });

    test('dHash compares adjacent pixels row by row', () {
      final gradient = [
        for (var r = 0; r < 8; r++) [for (var c = 0; c < 9; c++) c * 10],
      ];
      final flat = [for (var r = 0; r < 8; r++) List.filled(9, 128)];
      final falling = [
        for (var r = 0; r < 8; r++) [for (var c = 0; c < 9; c++) 255 - c * 10],
      ];
      expect(differenceHash(flat), '0000000000000000');
      expect(differenceHash(falling), 'ffffffffffffffff');
      expect(differenceHash(gradient), '0000000000000000');
      expect(hammingDistance('ffffffffffffffff', '0000000000000000'), 64);
      expect(hammingDistance('ff00000000000000', 'fe00000000000000'), 1);
      expect(
        () => differenceHash([
          [1, 2],
        ]),
        throwsArgumentError,
      );
    });

    test('similar images below the threshold produce warnings only', () {
      final existing = [
        ImageFingerprint(
          receiptId: 'r1',
          assetId: 'a1',
          dHash: 'ff00ff00ff00ff00',
        ),
        ImageFingerprint(
          receiptId: 'r2',
          assetId: 'a2',
          dHash: '00ff00ff00ff00ff',
        ),
      ];
      final warnings = findSimilarImages(
        const ImageFingerprint(
          receiptId: 'r3',
          assetId: 'a3',
          dHash: 'ff00ff00ff00ff01',
        ),
        existing,
      );
      expect(warnings.single.otherReceiptId, 'r1');
      expect(warnings.single.kind, DuplicateKind.similarImage);
      expect(warnings.single.detail, contains('1'));
    });

    test('economic duplicates warn but legitimate repeats stay possible', () {
      final fields = ReceiptFields(
        merchant: 'Coffee Cart',
        date: d('2026-07-01'),
        total: m('4.50'),
      );
      final others = {
        'r1': ReceiptFields(
          merchant: 'COFFEE CART',
          date: d('2026-07-01'),
          total: m('4.50'),
        ),
        'r2': ReceiptFields(
          merchant: 'Coffee Cart',
          date: d('2026-07-02'),
          total: m('4.50'),
        ),
        'r3': const ReceiptFields(merchant: 'Coffee Cart'),
      };
      final warnings = findEconomicDuplicates('r9', fields, others);
      expect(warnings.single.otherReceiptId, 'r1');
      expect(warnings.single.kind, DuplicateKind.economic);
    });
  });

  group('source reconciliation (MATCH 03, A08)', () {
    final receiptJournal = expense(
      'j-receipt',
      '63.25',
      '2026-07-01',
      account: 'card',
      payee: 'Woolworths',
    );
    ImportRow row(String date, String amount, String description) => ImportRow(
      rowNumber: 2,
      date: d(date),
      amount: m(amount),
      description: description,
      raw: const [],
    );

    test('A08: a bank row matching a receipt entry is proposed, not added', () {
      final proposals = proposeSourceMatches(
        row('2026-07-02', '-63.25', 'WOOLWORTHS 1234 SYDNEY'),
        accountId: 'card',
        journals: [
          receiptJournal,
          expense('other', '63.25', '2026-07-02', account: 'bank'),
        ],
        receiptJournalIds: {'j-receipt'},
      );
      expect(proposals.single.journal.id, 'j-receipt');
      expect(proposals.single.receiptCreated, isTrue);
      expect(proposals.single.reasons, isNotEmpty);
    });

    test('changed amounts are never proposed as the same purchase', () {
      final proposals = proposeSourceMatches(
        row('2026-07-02', '-64.25', 'WOOLWORTHS'),
        accountId: 'card',
        journals: [receiptJournal],
        receiptJournalIds: {'j-receipt'},
      );
      expect(proposals, isEmpty);
    });

    test('journals already matched to another source are skipped', () {
      final proposals = proposeSourceMatches(
        row('2026-07-02', '-63.25', 'WOOLWORTHS'),
        accountId: 'card',
        journals: [receiptJournal],
        receiptJournalIds: {'j-receipt'},
        alreadyMatchedJournalIds: {'j-receipt'},
      );
      expect(proposals, isEmpty);
    });
  });

  group('pending to posted (MATCH 03)', () {
    SourceRecord record(
      String id, {
      required SourceStatus status,
      String amount = '-50.00',
      String date = '2026-07-01',
      String description = 'UBER EATS SYDNEY',
      String? reference,
      String? pendingReference,
    }) => SourceRecord(
      id: id,
      batchId: 'b1',
      accountId: 'card',
      rowNumber: 1,
      fingerprint: id,
      raw: const [],
      date: d(date),
      amount: m(amount),
      description: description,
      reference: reference,
      pendingReference: pendingReference,
      status: status,
      decision: SourceDecision.created,
      journalId: 'journal-$id',
    );

    test('a provider-supplied link wins and needs no heuristic review', () {
      final pending = [
        record('p1', status: SourceStatus.pending, reference: 'AUTH-1'),
        record('p2', status: SourceStatus.pending, reference: 'AUTH-2'),
      ];
      final match = matchPendingToPosted(
        record(
          'posted',
          status: SourceStatus.posted,
          amount: '-55.00',
          pendingReference: 'AUTH-2',
        ),
        pending,
      )!;
      expect(match.pending.id, 'p2');
      expect(match.basis, PendingLinkBasis.provider);
      expect(match.requiresReview, isFalse);
      expect(match.amountChanged, isTrue);
    });

    test('a heuristic match with identical details is proposed', () {
      final match = matchPendingToPosted(
        record('posted', status: SourceStatus.posted, date: '2026-07-02'),
        [record('p1', status: SourceStatus.pending)],
      )!;
      expect(match.basis, PendingLinkBasis.heuristic);
      expect(match.dateChanged, isTrue);
      expect(match.requiresReview, isTrue);
    });

    test('identical amount and date via heuristic needs no extra review', () {
      final match = matchPendingToPosted(
        record('posted', status: SourceStatus.posted),
        [record('p1', status: SourceStatus.pending)],
      )!;
      expect(match.requiresReview, isFalse);
    });

    test(
      'changed amounts are proposed for review, unrelated entries never',
      () {
        final tipped = matchPendingToPosted(
          record('posted', status: SourceStatus.posted, amount: '-55.00'),
          [record('p1', status: SourceStatus.pending)],
        )!;
        expect(tipped.requiresReview, isTrue);
        expect(tipped.amountChanged, isTrue);
        expect(
          matchPendingToPosted(
            record('posted', status: SourceStatus.posted, amount: '-500.00'),
            [record('p1', status: SourceStatus.pending)],
          ),
          isNull,
        );
        expect(
          matchPendingToPosted(
            record(
              'posted',
              status: SourceStatus.posted,
              description: 'NETFLIX',
            ),
            [record('p1', status: SourceStatus.pending)],
          ),
          isNull,
        );
      },
    );

    test('two equally plausible pending entries need review', () {
      final match = matchPendingToPosted(
        record('posted', status: SourceStatus.posted),
        [
          record('p1', status: SourceStatus.pending),
          record('p2', status: SourceStatus.pending),
        ],
      )!;
      expect(match.requiresReview, isTrue);
      expect(match.alternatives.map((r) => r.id), ['p2']);
    });
  });
}
