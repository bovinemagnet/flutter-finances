import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);
  int u(String text) => parseUnits(text);

  final chart = Chart(
    currency: aud,
    accounts: const [
      Account(id: 'bank', name: 'Bank', type: AccountType.transaction),
      Account(id: 'shares', name: 'Shares', type: AccountType.investment),
      Account(id: 'super', name: 'Super', type: AccountType.superannuation),
      Account(
        id: 'hidden',
        name: 'Hidden',
        type: AccountType.investment,
        includeInNetWorth: false,
      ),
    ],
    categories: const [],
  );
  final factory = JournalFactory(chart);

  const vas = Holding(
    id: 'h-vas',
    securityCode: 'VAS',
    name: 'Vanguard Australian Shares',
    accountId: 'shares',
  );
  const bhp = Holding(
    id: 'h-bhp',
    securityCode: 'BHP',
    name: 'BHP Group',
    accountId: 'shares',
  );
  const fund = Holding(
    id: 'h-fund',
    securityCode: 'BALANCED',
    name: 'Balanced option',
    accountId: 'super',
  );

  group('units', () {
    test('are integer micro-units with six decimals', () {
      expect(unitsScale, 1000000);
      expect(parseUnits('12.5'), 12500000);
      expect(parseUnits('0.000001'), 1);
      expect(formatUnits(12500000), '12.500000');
      expect(() => parseUnits('1.0000001'), throwsFormatException);
    });
  });

  group('valuation rounding', () {
    test('units times price rounds half away from zero to the cent', () {
      // 3.333333 × 1.50 = 4.9999995, which rounds up to 5.00.
      expect(valueOfUnits(u('3.333333'), m('1.50')), m('5.00'));
      // 0.5 × 0.01 = 0.005, exactly half a cent, rounds up.
      expect(valueOfUnits(u('0.5'), m('0.01')), m('0.01'));
      // 0.499999 × 0.01 is just under half a cent.
      expect(valueOfUnits(u('0.499999'), m('0.01')), m('0.00'));
      // A negative product rounds away from zero as well.
      expect(valueOfUnits(-u('0.5'), m('0.01')), m('-0.01'));
    });

    test('large holdings do not overflow before rounding', () {
      expect(valueOfUnits(u('900000000'), m('1000.00')), m('900000000000.00'));
    });
  });

  group('events', () {
    test('buy, sell and split adjust units in date order', () {
      final events = [
        HoldingEvent.sell(
          id: 'e3',
          holdingId: 'h-vas',
          date: d('2026-09-01'),
          units: u('40'),
        ),
        HoldingEvent.buy(
          id: 'e1',
          holdingId: 'h-vas',
          date: d('2026-07-01'),
          units: u('100'),
        ),
        HoldingEvent.split(
          id: 'e2',
          holdingId: 'h-vas',
          date: d('2026-08-01'),
          numerator: 2,
          denominator: 1,
        ),
        HoldingEvent.buy(
          id: 'other',
          holdingId: 'h-bhp',
          date: d('2026-07-01'),
          units: u('5'),
        ),
      ];
      expect(unitsHeld(events, holdingId: 'h-vas'), u('160'));
      expect(
        unitsHeld(events, holdingId: 'h-vas', asOf: d('2026-07-31')),
        u('100'),
      );
      expect(
        unitsHeld(events, holdingId: 'h-vas', asOf: d('2026-08-01')),
        u('200'),
      );
      expect(unitsHeld(events, holdingId: 'h-vas', asOf: d('2026-06-30')), 0);
    });

    test('a consolidation rounds micro-units half away from zero', () {
      final events = [
        HoldingEvent.buy(
          id: 'b',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: u('10'),
        ),
        // One for three: 10 / 3 = 3.3333333..., kept as 3.333333.
        HoldingEvent.split(
          id: 's',
          holdingId: 'h',
          date: d('2026-07-02'),
          numerator: 1,
          denominator: 3,
        ),
      ];
      expect(unitsHeld(events, holdingId: 'h'), u('3.333333'));
      final halfMicroUnit = [
        HoldingEvent.buy(
          id: 'b',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: u('0.000002'),
        ),
        // 0.000002 × 3 / 4 = 0.0000015, half a micro-unit, rounds up.
        HoldingEvent.split(
          id: 's',
          holdingId: 'h',
          date: d('2026-07-02'),
          numerator: 3,
          denominator: 4,
        ),
      ];
      expect(unitsHeld(halfMicroUnit, holdingId: 'h'), 2);
    });

    test('events on the same date apply in the order given', () {
      final events = [
        HoldingEvent.buy(
          id: 'b',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: u('10'),
        ),
        HoldingEvent.split(
          id: 's',
          holdingId: 'h',
          date: d('2026-07-01'),
          numerator: 2,
          denominator: 1,
        ),
        HoldingEvent.buy(
          id: 'b2',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: u('1'),
        ),
      ];
      expect(unitsHeld(events, holdingId: 'h'), u('21'));
    });

    test('selling more units than held is rejected', () {
      final events = [
        HoldingEvent.buy(
          id: 'b',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: u('1'),
        ),
        HoldingEvent.sell(
          id: 's',
          holdingId: 'h',
          date: d('2026-07-02'),
          units: u('1.000001'),
        ),
      ];
      expect(
        () => unitsHeld(events, holdingId: 'h'),
        throwsA(
          isA<HoldingException>().having(
            (e) => e.code,
            'code',
            HoldingError.insufficientUnits,
          ),
        ),
      );
    });

    test('event quantities and ratios must be positive', () {
      expect(
        () => HoldingEvent.buy(
          id: 'b',
          holdingId: 'h',
          date: d('2026-07-01'),
          units: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => HoldingEvent.split(
          id: 's',
          holdingId: 'h',
          date: d('2026-07-01'),
          numerator: 0,
          denominator: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('prices', () {
    test('the latest price on or before the date is used', () {
      final book = PriceBook([
        SecurityPrice(
          securityCode: 'VAS',
          date: d('2026-07-01'),
          price: m('90.00'),
        ),
        SecurityPrice(
          securityCode: 'VAS',
          date: d('2026-08-01'),
          price: m('95.00'),
        ),
        SecurityPrice(
          securityCode: 'BHP',
          date: d('2026-07-15'),
          price: m('40.00'),
        ),
      ]);
      expect(book.latest('VAS', d('2026-06-30')), isNull);
      expect(book.latest('VAS', d('2026-07-31'))!.price, m('90.00'));
      expect(book.latest('VAS', d('2026-08-01'))!.price, m('95.00'));
      expect(book.latest('XYZ', d('2026-08-01')), isNull);
    });

    test('a later entry for the same date replaces an earlier one', () {
      final book = PriceBook([
        SecurityPrice(
          securityCode: 'VAS',
          date: d('2026-07-01'),
          price: m('90.00'),
        ),
        SecurityPrice(
          securityCode: 'VAS',
          date: d('2026-07-01'),
          price: m('91.00'),
        ),
      ]);
      expect(book.latest('VAS', d('2026-07-01'))!.price, m('91.00'));
    });
  });

  final events = [
    HoldingEvent.buy(
      id: 'e1',
      holdingId: 'h-vas',
      date: d('2026-07-01'),
      units: u('10.5'),
    ),
    HoldingEvent.buy(
      id: 'e2',
      holdingId: 'h-bhp',
      date: d('2026-07-01'),
      units: u('3.333333'),
    ),
    HoldingEvent.buy(
      id: 'e3',
      holdingId: 'h-fund',
      date: d('2026-07-01'),
      units: u('1000'),
    ),
  ];
  final prices = PriceBook([
    SecurityPrice(
      securityCode: 'VAS',
      date: d('2026-07-01'),
      price: m('100.01'),
    ),
    SecurityPrice(securityCode: 'BHP', date: d('2026-07-01'), price: m('1.50')),
    SecurityPrice(
      securityCode: 'VAS',
      date: d('2026-08-15'),
      price: m('110.00'),
    ),
    SecurityPrice(
      securityCode: 'BALANCED',
      date: d('2026-07-01'),
      price: m('1.23'),
    ),
  ]);

  group('portfolio valuation', () {
    test('values each holding of the account and totals them', () {
      final valuation = valuePortfolio(
        accountId: 'shares',
        currency: aud,
        holdings: const [vas, bhp, fund],
        events: events,
        prices: prices,
        asOf: d('2026-07-31'),
      );
      expect(valuation.holdings.map((h) => h.holding.id), ['h-vas', 'h-bhp']);
      // 10.5 × 100.01 = 1050.105, rounds to 1050.11.
      expect(valuation.holdings[0].value, m('1050.11'));
      expect(valuation.holdings[0].units, u('10.5'));
      expect(valuation.holdings[0].price!.date, d('2026-07-01'));
      expect(valuation.holdings[1].value, m('5.00'));
      expect(valuation.total, m('1055.11'));
      expect(valuation.isComplete, isTrue);
    });

    test('a holding without a price is reported and left out of the total', () {
      final valuation = valuePortfolio(
        accountId: 'shares',
        currency: aud,
        holdings: const [vas, bhp],
        events: events,
        prices: PriceBook([
          SecurityPrice(
            securityCode: 'VAS',
            date: d('2026-07-01'),
            price: m('100.00'),
          ),
        ]),
        asOf: d('2026-07-31'),
      );
      expect(valuation.isComplete, isFalse);
      expect(valuation.unpriced.map((h) => h.holding.id), ['h-bhp']);
      expect(valuation.holdings[1].value, isNull);
      expect(valuation.total, m('1050.00'));
    });

    test('a holding with no units is worth nothing even without a price', () {
      final valuation = valuePortfolio(
        accountId: 'shares',
        currency: aud,
        holdings: const [bhp],
        events: const [],
        prices: PriceBook(const []),
        asOf: d('2026-07-31'),
      );
      expect(valuation.isComplete, isTrue);
      expect(valuation.total, m('0.00'));
    });
  });

  group('balance adjustment proposal', () {
    final ledger = LedgerProjection(chart, [
      factory.build(
        TransactionDraft(
          id: 'open',
          type: TransactionType.openingBalance,
          accountId: 'shares',
          amount: m('1000.00'),
          effectiveDate: d('2026-07-01'),
        ),
      ),
    ]);

    PortfolioValuation valuation(LocalDate asOf) => valuePortfolio(
      accountId: 'shares',
      currency: aud,
      holdings: const [vas, bhp],
      events: events,
      prices: prices,
      asOf: asOf,
    );

    test('proposes an adjustment draft for the difference', () {
      final proposal = proposeValuationAdjustment(
        ledger,
        valuation(d('2026-07-31')),
        draftId: 'adj-1',
      );
      expect(proposal.recordedBalance, m('1000.00'));
      expect(proposal.valuedBalance, m('1055.11'));
      expect(proposal.difference, m('55.11'));
      final draft = proposal.draft!;
      expect(draft.type, TransactionType.adjustment);
      expect(draft.accountId, 'shares');
      expect(draft.amount, m('55.11'));
      expect(draft.effectiveDate, d('2026-07-31'));
      expect(draft.id, 'adj-1');

      // Nothing is posted until the user confirms the draft.
      expect(ledger.displayBalance('shares'), m('1000.00'));
      final confirmed = LedgerProjection(chart, [
        ...ledger.journals,
        factory.build(draft),
      ]);
      expect(confirmed.displayBalance('shares'), m('1055.11'));
    });

    test('a fall in value proposes a negative adjustment', () {
      final proposal = proposeValuationAdjustment(
        LedgerProjection(chart, [
          factory.build(
            TransactionDraft(
              id: 'open',
              type: TransactionType.openingBalance,
              accountId: 'shares',
              amount: m('2000.00'),
              effectiveDate: d('2026-07-01'),
            ),
          ),
        ]),
        valuation(d('2026-07-31')),
      );
      expect(proposal.difference, m('-944.89'));
      expect(proposal.draft!.amount, m('-944.89'));
    });

    test('no draft when the balance already matches', () {
      final matched = LedgerProjection(chart, [
        factory.build(
          TransactionDraft(
            id: 'open',
            type: TransactionType.openingBalance,
            accountId: 'shares',
            amount: m('1055.11'),
            effectiveDate: d('2026-07-01'),
          ),
        ),
      ]);
      final proposal = proposeValuationAdjustment(
        matched,
        valuation(d('2026-07-31')),
      );
      expect(proposal.difference, m('0.00'));
      expect(proposal.draft, isNull);
    });

    test('no draft while a holding has no price', () {
      final proposal = proposeValuationAdjustment(
        ledger,
        valuePortfolio(
          accountId: 'shares',
          currency: aud,
          holdings: const [vas, bhp],
          events: events,
          prices: PriceBook(const []),
          asOf: d('2026-07-31'),
        ),
      );
      expect(proposal.draft, isNull);
      expect(proposal.isComplete, isFalse);
    });

    test('only investment and superannuation accounts are valued', () {
      expect(
        () => proposeValuationAdjustment(
          ledger,
          valuePortfolio(
            accountId: 'bank',
            currency: aud,
            holdings: const [],
            events: const [],
            prices: PriceBook(const []),
            asOf: d('2026-07-31'),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('valuation history', () {
    test('month-end values per account line up with net worth history', () {
      final range = DateRange(d('2026-07-01'), d('2026-09-15'));
      final hidden = const Holding(
        id: 'h-hidden',
        securityCode: 'VAS',
        name: 'Hidden VAS',
        accountId: 'hidden',
      );
      final report = holdingsValuationHistory(
        chart,
        holdings: [vas, bhp, fund, hidden],
        events: [
          ...events,
          HoldingEvent.buy(
            id: 'e4',
            holdingId: 'h-hidden',
            date: d('2026-07-01'),
            units: u('1'),
          ),
        ],
        prices: prices,
        range: range,
      );
      final ledgerReport = netWorthHistory(LedgerProjection(chart, []), range);
      expect(
        report.rows.map((r) => r.key),
        ledgerReport.rows.map((r) => r.key),
      );
      expect(report.columns.map((c) => c.key), [
        'shares',
        'super',
        'total',
        'unpriced',
      ]);
      final july = report.row('2026-07-31')!;
      expect(july.amount('shares'), m('1055.11'));
      expect(july.amount('super'), m('1230.00'));
      expect(july.amount('total'), m('2285.11'));
      expect(july.count('unpriced'), 0);
      // 10.5 × 110.00 + 5.00 after the August price.
      expect(report.row('2026-08-31')!.amount('shares'), m('1160.00'));
      expect(report.row('2026-09-15')!.amount('total'), m('2390.00'));
    });

    test('valuationHistory values an account on each date', () {
      final history = valuationHistory(
        accountId: 'shares',
        currency: aud,
        holdings: const [vas, bhp],
        events: events,
        prices: prices,
        dates: [d('2026-06-30'), d('2026-07-31'), d('2026-08-31')],
      );
      expect(history.map((v) => v.total), [
        m('0.00'),
        m('1055.11'),
        m('1160.00'),
      ]);
    });
  });

  group('JSON', () {
    Map<String, Object?> viaText(Map<String, Object?> json) =>
        (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

    test('holdings round-trip', () {
      final json = holdingToJson(vas);
      expect(json, {
        'id': 'h-vas',
        'securityCode': 'VAS',
        'name': 'Vanguard Australian Shares',
        'accountId': 'shares',
      });
      expect(holdingToJson(holdingFromJson(viaText(json))), json);
    });

    test('events round-trip with units as micro-units', () {
      final buy = HoldingEvent.buy(
        id: 'e1',
        holdingId: 'h-vas',
        date: d('2026-07-01'),
        units: u('10.5'),
      );
      final split = HoldingEvent.split(
        id: 'e2',
        holdingId: 'h-vas',
        date: d('2026-08-01'),
        numerator: 3,
        denominator: 2,
      );
      expect(holdingEventToJson(buy), {
        'id': 'e1',
        'holdingId': 'h-vas',
        'date': '2026-07-01',
        'type': 'buy',
        'unitsMicro': 10500000,
        'splitNumerator': null,
        'splitDenominator': null,
      });
      for (final event in [buy, split]) {
        final json = holdingEventToJson(event);
        expect(holdingEventToJson(holdingEventFromJson(viaText(json))), json);
      }
      expect(holdingEventToJson(split)['unitsMicro'], isNull);
    });

    test('prices round-trip in minor units', () {
      final price = SecurityPrice(
        securityCode: 'VAS',
        date: d('2026-07-01'),
        price: m('100.01'),
      );
      final json = securityPriceToJson(price);
      expect(json, {
        'securityCode': 'VAS',
        'date': '2026-07-01',
        'priceMinor': 10001,
      });
      expect(
        securityPriceToJson(securityPriceFromJson(viaText(json), aud)),
        json,
      );
    });
  });
}
