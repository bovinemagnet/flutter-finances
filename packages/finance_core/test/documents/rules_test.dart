import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

CategorisationRule rule(
  String id, {
  int priority = 10,
  String categoryId = 'groceries',
  String? merchant,
  String? description,
  Set<String> accountIds = const {},
  Money? minAmount,
  Money? maxAmount,
  Set<String> tags = const {},
  bool enabled = true,
}) => CategorisationRule(
  id: id,
  name: id,
  priority: priority,
  categoryId: categoryId,
  merchant: merchant,
  descriptionContains: description,
  accountIds: accountIds,
  minAmount: minAmount,
  maxAmount: maxAmount,
  tags: tags,
  enabled: enabled,
);

RuleSubject subject({
  String merchant = 'WOOLWORTHS 1234 SYDNEY',
  String? description,
  String account = 'bank',
  String amount = '63.25',
  Set<String> tags = const {},
  CategorySource source = CategorySource.none,
  String? current,
}) => RuleSubject(
  merchant: merchant,
  description: description,
  accountId: account,
  amount: m(amount),
  tags: tags,
  currentCategoryId: current,
  categorySource: source,
);

void main() {
  group('rule conditions (AUTO 01)', () {
    test(
      'match normalised merchant words, description, account, amount and tags',
      () {
        expect(rule('r', merchant: 'Woolworths').matches(subject()), isTrue);
        expect(rule('r', merchant: 'Coles').matches(subject()), isFalse);
        expect(
          rule(
            'r',
            description: 'direct debit',
          ).matches(subject(description: 'DIRECT DEBIT 123')),
          isTrue,
        );
        expect(
          rule(
            'r',
            merchant: 'Woolworths',
            accountIds: {'card'},
          ).matches(subject()),
          isFalse,
        );
        expect(
          rule(
            'r',
            merchant: 'Woolworths',
            minAmount: m('50.00'),
            maxAmount: m('70.00'),
          ).matches(subject()),
          isTrue,
        );
        expect(
          rule(
            'r',
            merchant: 'Woolworths',
            maxAmount: m('50.00'),
          ).matches(subject()),
          isFalse,
        );
        expect(
          rule('r', tags: {'work'}).matches(subject(tags: {'work', 'travel'})),
          isTrue,
        );
        expect(rule('r', tags: {'work'}).matches(subject()), isFalse);
        expect(
          rule('r', merchant: 'Woolworths', enabled: false).matches(subject()),
          isFalse,
        );
      },
    );

    test('a rule needs at least one condition and a sensible range', () {
      expect(() => rule('r'), throwsArgumentError);
      expect(
        () => rule('r', minAmount: m('5.00'), maxAmount: m('1.00')),
        throwsArgumentError,
      );
    });
  });

  group('precedence', () {
    final rules = [
      rule(
        'broad',
        priority: 20,
        merchant: 'Woolworths',
        categoryId: 'groceries',
      ),
      rule(
        'narrow',
        priority: 5,
        merchant: 'Woolworths',
        maxAmount: m('10.00'),
        categoryId: 'dining',
      ),
    ];

    test('explicit user categorisation wins over rules', () {
      final decision = categorise(
        subject(source: CategorySource.user, current: 'fuel'),
        rules,
      );
      expect(decision!.categoryId, 'fuel');
      expect(decision.source, CategorySource.user);
    });

    test('rules apply in priority order, lower numbers first', () {
      expect(categorise(subject(amount: '8.00'), rules)!.ruleId, 'narrow');
      expect(categorise(subject(amount: '63.25'), rules)!.ruleId, 'broad');
    });

    test('rules win over general suggestions, which fill the gaps', () {
      expect(
        categorise(subject(), rules, suggestion: 'fuel')!.source,
        CategorySource.rule,
      );
      final fallback = categorise(
        subject(merchant: 'Unknown'),
        rules,
        suggestion: 'fuel',
      )!;
      expect(fallback.categoryId, 'fuel');
      expect(fallback.source, CategorySource.suggestion);
      expect(categorise(subject(merchant: 'Unknown'), rules), isNull);
    });

    test(
      'previous rule results are re-evaluated, suggestions are replaced',
      () {
        final decision = categorise(
          subject(source: CategorySource.suggestion, current: 'fuel'),
          rules,
        )!;
        expect(decision.categoryId, 'groceries');
      },
    );
  });

  group('bulk application with preview and undo', () {
    final posted = expense(
      'posted',
      '63.25',
      '2026-07-01',
      category: 'uncategorised',
      payee: 'WOOLWORTHS 1234',
    );
    final pending = expense(
      'pending',
      '12.00',
      '2026-07-02',
      category: 'uncategorised',
      payee: 'Woolworths Metro',
      status: JournalStatus.pending,
    );
    final userSet = expense(
      'user',
      '20.00',
      '2026-07-03',
      category: 'dining',
      payee: 'Woolworths cafe',
    );
    final split = JournalFactory(testChart).build(
      TransactionDraft(
        id: 'split',
        type: TransactionType.expense,
        accountId: 'bank',
        amount: m('30.00'),
        effectiveDate: d('2026-07-04'),
        splits: [Split('groceries', m('20.00')), Split('dining', m('10.00'))],
        payee: 'Woolworths',
      ),
    );
    final other = expense(
      'other',
      '5.00',
      '2026-07-05',
      category: 'uncategorised',
      payee: 'Cafe',
    );
    final journals = [posted, pending, userSet, split, other];
    final sources = {'user': CategorySource.user};
    final rules = [
      rule('woolies', merchant: 'Woolworths', categoryId: 'groceries'),
    ];

    test('preview lists affected entries and why others are skipped', () {
      final preview = previewRuleApplication(
        rules: rules,
        journals: journals,
        chart: testChart,
        categorySources: sources,
      );
      expect(preview.changes.map((c) => c.journalId).toList(), [
        'posted',
        'pending',
      ]);
      expect(preview.changes.first.fromCategoryId, 'uncategorised');
      expect(preview.changes.first.toCategoryId, 'groceries');
      expect(preview.changes.first.ruleId, 'woolies');
      expect(preview.skipped.map((s) => (s.journalId, s.reason)).toSet(), {
        ('user', RuleSkipReason.userCategorised),
        ('split', RuleSkipReason.splitEntry),
      });
    });

    test(
      'applying corrects posted entries, keeps balances and can be undone',
      () {
        final preview = previewRuleApplication(
          rules: rules,
          journals: journals,
          chart: testChart,
          categorySources: sources,
        );
        final result = applyRuleChanges(
          preview,
          journals,
          chart: testChart,
          categorySources: sources,
          now: DateTime.utc(2026, 7, 10),
        );

        final correction = result.corrections.single;
        expect(correction.original.id, 'posted');
        expect(correction.original.status, JournalStatus.reversed);
        expect(correction.replacement!.amountFor('groceries'), m('63.25'));
        final replaced = result.replacements.single;
        expect(replaced.id, 'pending');
        expect(replaced.status, JournalStatus.pending);
        expect(replaced.amountFor('groceries'), m('12.00'));
        expect(
          result.categorySources[correction.replacement!.id],
          CategorySource.rule,
        );

        final before = LedgerProjection(testChart, journals);
        final afterJournals = [
          ...journals.where((j) => j.id != 'posted' && j.id != 'pending'),
          ...correction.journals,
          replaced,
        ];
        final after = LedgerProjection(testChart, afterJournals);
        expect(after.displayBalance('bank'), before.displayBalance('bank'));
        expect(
          after.displayBalance('bank', includePending: true),
          before.displayBalance('bank', includePending: true),
        );
        expect(
          after.expenses(d('2026-07-01'), d('2026-07-31')),
          before.expenses(d('2026-07-01'), d('2026-07-31')),
        );
        expect(
          after.categoryNet('groceries', d('2026-07-01'), d('2026-07-31')),
          m('83.25'),
        );
        for (final journal in afterJournals) {
          expect(validatePostings(journal.postings), isEmpty);
        }

        expect(result.undo.entries.length, 2);
        final undone = undoRuleApplication(
          result.undo,
          afterJournals,
          chart: testChart,
          now: DateTime.utc(2026, 7, 11),
        );
        expect(undone.conflicts, isEmpty);
        final restored = [
          ...afterJournals.where(
            (j) =>
                !undone.corrections.any((c) => c.original.id == j.id) &&
                !undone.replacements.any((r) => r.id == j.id),
          ),
          for (final c in undone.corrections) ...c.journals,
          ...undone.replacements,
        ];
        final back = LedgerProjection(testChart, restored);
        expect(
          back.categoryNet('groceries', d('2026-07-01'), d('2026-07-31')),
          m('20.00'),
        );
        expect(
          back.categoryNet('uncategorised', d('2026-07-01'), d('2026-07-31')),
          m('68.25'),
        );
        expect(back.displayBalance('bank'), before.displayBalance('bank'));
        expect(undone.categorySources.values.toSet(), {CategorySource.none});
      },
    );

    test('undo refuses entries edited after the rules ran', () {
      final preview = previewRuleApplication(
        rules: rules,
        journals: [posted],
        chart: testChart,
      );
      final result = applyRuleChanges(
        preview,
        [posted],
        chart: testChart,
        now: DateTime.utc(2026, 7, 10),
      );
      final replacement = result.corrections.single.replacement!;
      final edited = correctJournal(replacement, null);
      final undone = undoRuleApplication(
        result.undo,
        [
          ...result.corrections.single.journals.where(
            (j) => j.id != replacement.id,
          ),
          ...edited.journals,
        ],
        chart: testChart,
        now: DateTime.utc(2026, 7, 11),
      );
      expect(undone.corrections, isEmpty);
      expect(undone.conflicts, [replacement.id]);
    });

    test('reconciliation state survives recategorisation', () {
      final reconciliation = Reconciliation(
        accountId: 'bank',
        statementDate: d('2026-07-31'),
        statementBalance: m('-63.25'),
        clearedJournalIds: {'posted'},
      );
      expect(
        reconciliation.difference(LedgerProjection(testChart, [posted])).isZero,
        isTrue,
      );
      final preview = previewRuleApplication(
        rules: rules,
        journals: [posted],
        chart: testChart,
      );
      final result = applyRuleChanges(
        preview,
        [posted],
        chart: testChart,
        now: DateTime.utc(2026, 7, 10),
      );
      final carried = Reconciliation(
        accountId: 'bank',
        statementDate: d('2026-07-31'),
        statementBalance: m('-63.25'),
        clearedJournalIds: carryClearedJournals(
          reconciliation.clearedJournalIds,
          result.corrections,
        ),
      );
      final ledger = LedgerProjection(
        testChart,
        result.corrections.single.journals,
      );
      expect(carried.difference(ledger).isZero, isTrue);
    });

    test('incompatible categories are skipped', () {
      final incomeRule = [
        rule('pay', merchant: 'Woolworths', categoryId: 'salary'),
      ];
      final preview = previewRuleApplication(
        rules: incomeRule,
        journals: [posted],
        chart: testChart,
      );
      expect(preview.changes, isEmpty);
      expect(
        preview.skipped.single.reason,
        RuleSkipReason.incompatibleCategory,
      );
    });
  });

  test('rules choose categories for imported rows', () {
    final chooser = ruleCategoryChooser([
      rule('woolies', merchant: 'Woolworths', accountIds: {'bank'}),
    ], 'bank');
    ImportRow row(String description) => ImportRow(
      rowNumber: 2,
      date: d('2026-07-01'),
      amount: m('-63.25'),
      description: description,
      raw: const [],
    );
    expect(chooser(row('WOOLWORTHS 1234 SYDNEY')), 'groceries');
    expect(chooser(row('BP CONNECT')), isNull);
  });
}
