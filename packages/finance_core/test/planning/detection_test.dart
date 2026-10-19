import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
      Account(id: 'card', name: 'Card', type: AccountType.creditCard),
    ],
    categories: const [
      Category(id: 'streaming', name: 'Streaming', kind: CategoryKind.expense),
      Category(id: 'groceries', name: 'Groceries', kind: CategoryKind.expense),
      Category(id: 'gifts', name: 'Gifts', kind: CategoryKind.expense),
      Category(id: 'travel', name: 'Travel', kind: CategoryKind.expense),
    ],
  );
  final factory = JournalFactory(chart);
  var counter = 0;
  Journal buy(
    String date,
    String amount, {
    String? payee,
    String category = 'groceries',
    String account = 'card',
    String? id,
  }) => factory.build(
    TransactionDraft(
      id: id ?? 'j${counter++}',
      type: TransactionType.expense,
      accountId: account,
      amount: m(amount),
      effectiveDate: d(date),
      splits: [Split(category, m(amount))],
      payee: payee,
      enteredAt: DateTime.utc(2026),
    ),
  );

  group('subscription detection', () {
    final netflix = [
      for (final date in [
        '2026-05-03',
        '2026-06-03',
        '2026-07-03',
        '2026-08-04',
        '2026-09-03',
      ])
        buy(date, '22.99', payee: 'NETFLIX.COM', category: 'streaming'),
    ];

    test('proposes a monthly schedule for a regular merchant charge', () {
      final ledger = LedgerProjection(chart, netflix);
      final proposals = detectSubscriptions(
        ledger: ledger,
        today: d('2026-09-20'),
      );
      final proposal = proposals.single;
      expect(proposal.payee, 'NETFLIX.COM');
      expect(proposal.frequency, Frequency.monthly);
      expect(proposal.amount, m('22.99'));
      expect(proposal.amountVaries, isFalse);
      expect(proposal.accountId, 'card');
      expect(proposal.categoryId, 'streaming');
      expect(proposal.journalIds, [for (final j in netflix) j.id]);
      expect(proposal.lastDate, d('2026-09-03'));
      expect(proposal.nextDueDate, d('2026-10-03'));
      expect(proposal.confidence, DetectionConfidence.high);
      expect(proposal.reasons, {
        SubscriptionReason.sameMerchant,
        SubscriptionReason.identicalAmount,
        SubscriptionReason.regularInterval,
      });

      // The proposal is never confirmed on its own.
      final schedule = proposal.toSchedule(id: 's1');
      expect(schedule.confirmed, isFalse);
      expect(schedule.kind, ScheduleKind.expense);
      expect(schedule.recurrence.frequency, Frequency.monthly);
      expect(schedule.recurrence.start, d('2026-10-03'));
      expect(schedule.amount, m('22.99'));
      expect(schedule.payee, 'NETFLIX.COM');
    });

    test('similar amounts make an estimate and lower the confidence', () {
      final ledger = LedgerProjection(chart, [
        buy('2026-07-01', '50.00', payee: 'Gym Co'),
        buy('2026-07-15', '52.00', payee: 'Gym Co'),
        buy('2026-07-29', '51.00', payee: 'GYM CO PTY LTD'),
      ]);
      final proposal = detectSubscriptions(
        ledger: ledger,
        today: d('2026-08-01'),
      ).single;
      expect(proposal.frequency, Frequency.fortnightly);
      expect(proposal.amountVaries, isTrue);
      expect(proposal.amount, m('51.00'));
      expect(proposal.confidence, DetectionConfidence.medium);
      expect(proposal.reasons, contains(SubscriptionReason.similarAmount));
      expect(proposal.toSchedule(id: 's').isEstimate, isTrue);
      expect(proposal.nextDueDate, d('2026-08-12'));
    });

    test('ignores irregular, sparse, stale and already scheduled series', () {
      final irregular = [
        buy('2026-07-01', '10.00', payee: 'Corner Shop'),
        buy('2026-07-04', '10.00', payee: 'Corner Shop'),
        buy('2026-07-20', '10.00', payee: 'Corner Shop'),
      ];
      final sparse = [
        buy('2026-08-01', '9.99', payee: 'Music'),
        buy('2026-09-01', '9.99', payee: 'Music'),
      ];
      final stale = [
        for (final date in ['2026-01-10', '2026-02-10', '2026-03-10'])
          buy(date, '15.00', payee: 'Old Service'),
      ];
      final ledger = LedgerProjection(chart, [
        ...irregular,
        ...sparse,
        ...stale,
        ...netflix,
      ]);
      final scheduled = RecurringSchedule(
        id: 'n',
        name: 'Netflix',
        kind: ScheduleKind.expense,
        recurrence: Recurrence(
          frequency: Frequency.monthly,
          start: d('2026-10-03'),
        ),
        amount: m('22.99'),
        accountId: 'card',
        payee: 'Netflix',
      );
      expect(
        detectSubscriptions(
          ledger: ledger,
          today: d('2026-09-20'),
          existingSchedules: [scheduled],
        ),
        isEmpty,
      );
    });

    test('tolerates one irregular gap with low confidence', () {
      final ledger = LedgerProjection(chart, [
        for (final date in [
          '2026-03-10',
          '2026-04-10',
          '2026-06-10',
          '2026-07-10',
          '2026-08-10',
        ])
          buy(date, '5.00', payee: 'Cloud Storage'),
      ]);
      final proposal = detectSubscriptions(
        ledger: ledger,
        today: d('2026-08-20'),
      ).single;
      expect(proposal.confidence, DetectionConfidence.low);
      expect(
        proposal.reasons,
        contains(SubscriptionReason.oneIrregularInterval),
      );
    });

    test('becomes an explainable insight that acts on nothing', () {
      final ledger = LedgerProjection(chart, netflix);
      final proposals = detectSubscriptions(
        ledger: ledger,
        today: d('2026-09-20'),
      );
      final insights = generateInsights(
        period: DateRange(d('2026-09-01'), d('2026-09-30')),
        subscriptions: proposals,
      );
      final insight = insights.single;
      expect(insight.rule, InsightRule.possibleSubscription);
      expect(insight.key, proposals.single.key);
      expect(insight.entryIds, proposals.single.journalIds);
      expect(insight.period.start, d('2026-05-03'));
      expect(insight.period.end, d('2026-09-03'));
      expect(insight.trigger, contains('monthly'));
      expect(insight.amount, m('22.99'));
    });
  });

  group('unusual transactions', () {
    final history = [
      for (final (i, amount) in [
        '80.00',
        '95.00',
        '70.00',
        '85.00',
        '90.00',
        '75.00',
      ].indexed)
        buy('2026-0${i + 1}-15', amount, payee: 'Woolworths Metro'),
    ];

    test('flags a purchase far above the merchant median', () {
      final big = buy('2026-07-20', '260.00', payee: 'WOOLWORTHS METRO 1234');
      final normal = buy('2026-07-21', '99.00', payee: 'Woolworths Metro');
      final ledger = LedgerProjection(chart, [...history, big, normal]);
      final found = detectUnusualTransactions(
        ledger: ledger,
        period: DateRange(d('2026-07-01'), d('2026-07-31')),
      );
      final unusual = found.single;
      expect(unusual.journalId, big.id);
      expect(unusual.basis, AnomalyBasis.merchant);
      expect(unusual.median, m('82.50'));
      expect(unusual.deviation, m('7.50'));
      expect(unusual.historyJournalIds, [for (final j in history) j.id]);
      expect(unusual.key, 'unusualTransaction:${big.id}');
    });

    test('falls back to the category and needs enough history', () {
      final gifts = [
        for (final (i, amount) in [
          '20.00',
          '25.00',
          '30.00',
          '20.00',
          '25.00',
        ].indexed)
          buy('2026-0${i + 1}-02', amount, payee: 'Shop $i', category: 'gifts'),
      ];
      final big = buy(
        '2026-07-02',
        '150.00',
        payee: 'New Shop',
        category: 'gifts',
      );
      final period = DateRange(d('2026-07-01'), d('2026-07-31'));
      final found = detectUnusualTransactions(
        ledger: LedgerProjection(chart, [...gifts, big]),
        period: period,
      );
      expect(found.single.basis, AnomalyBasis.category);
      expect(found.single.basisKey, 'gifts');
      expect(
        detectUnusualTransactions(
          ledger: LedgerProjection(chart, [...gifts.skip(1), big]),
          period: period,
        ),
        isEmpty,
      );
    });

    test('identical history uses the ten per cent floor, not zero spread', () {
      final same = [
        for (var i = 1; i <= 5; i++)
          buy('2026-0$i-01', '100.00', payee: 'Insurer'),
      ];
      final period = DateRange(d('2026-06-01'), d('2026-06-30'));
      List<UnusualTransaction> check(String amount) =>
          detectUnusualTransactions(
            ledger: LedgerProjection(chart, [
              ...same,
              buy('2026-06-01', amount, payee: 'Insurer'),
            ]),
            period: period,
          );
      expect(check('101.00'), isEmpty);
      expect(check('150.00'), isEmpty);
      expect(check('152.00'), hasLength(1));
    });

    test('respects a minimum excess', () {
      final ledger = LedgerProjection(chart, [
        for (var i = 1; i <= 5; i++) buy('2026-0$i-01', '4.00', payee: 'Cafe'),
        buy('2026-06-01', '12.00', payee: 'Cafe'),
      ]);
      final period = DateRange(d('2026-06-01'), d('2026-06-30'));
      expect(
        detectUnusualTransactions(ledger: ledger, period: period),
        hasLength(1),
      );
      expect(
        detectUnusualTransactions(
          ledger: ledger,
          period: period,
          minimumExcess: m('20.00'),
        ),
        isEmpty,
      );
    });
  });

  group('spending spikes', () {
    final months = [
      for (final (i, amount) in ['100.00', '120.00', '90.00', '110.00'].indexed)
        buy('2026-0${i + 3}-10', amount, category: 'groceries'),
    ];

    test('flags a category far above its monthly median', () {
      final spike = buy('2026-07-12', '400.00', category: 'groceries');
      final travel = buy('2026-07-14', '300.00', category: 'travel');
      final ledger = LedgerProjection(chart, [...months, spike, travel]);
      final spikes = detectSpendingSpikes(
        ledger: ledger,
        month: d('2026-07-20'),
      );
      expect([for (final s in spikes) s.categoryId], ['groceries', 'travel']);
      final groceries = spikes.first;
      expect(groceries.spending, m('400.00'));
      expect(groceries.median, m('105.00'));
      expect(groceries.historyMonths, 4);
      expect(groceries.firstSpending, isFalse);
      expect(groceries.journalIds, [spike.id]);
      expect(groceries.month.start, d('2026-07-01'));
      expect(groceries.key, 'spendingSpike:groceries:2026-07-01');
      expect(spikes.last.firstSpending, isTrue);

      final insights = generateInsights(
        period: groceries.month,
        spendingSpikes: spikes,
      );
      expect(insights.first.rule, InsightRule.spendingSpike);
      expect(insights.first.entryIds, [spike.id]);
    });

    test('needs enough months of history', () {
      final ledger = LedgerProjection(chart, [
        buy('2026-06-10', '100.00'),
        buy('2026-07-12', '400.00'),
      ]);
      expect(
        detectSpendingSpikes(ledger: ledger, month: d('2026-07-20')),
        isEmpty,
      );
    });

    test('ordinary months are not spikes', () {
      final ledger = LedgerProjection(chart, [
        ...months,
        buy('2026-07-12', '130.00'),
      ]);
      expect(
        detectSpendingSpikes(ledger: ledger, month: d('2026-07-20')),
        isEmpty,
      );
    });
  });

  test('new rules keep their names in settings JSON', () {
    for (final rule in [
      InsightRule.possibleSubscription,
      InsightRule.unusualTransaction,
      InsightRule.spendingSpike,
    ]) {
      final setting = InsightRuleSetting(id: 'x', rule: rule, enabled: false);
      final json = insightRuleSettingToJson(setting);
      expect(insightRuleSettingFromJson(json, aud).rule, rule);
    }
  });
}
