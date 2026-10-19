import 'package:meta/meta.dart';

import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../ledger/transaction_draft.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'date_range.dart';
import 'report.dart';
import 'rounding.dart';

// Detailed investment holdings (P1, goals and net worth). Units are integer
// micro-units and prices are money in minor units, so no value here ever
// passes through binary floating point.

/// Micro-units in one unit: holdings keep six decimal places of units.
const int unitsScale = 1000000;

/// Parses a unit quantity such as `12.5` into micro-units without rounding;
/// more than six decimal places is rejected.
int parseUnits(String text) => parseMinor(text, 6);

/// Formats micro-units with all six decimal places, such as `12.500000`.
String formatUnits(int units) => formatMinor(units, 6);

/// The value of [units] micro-units at [unitPrice] per whole unit.
///
/// The exact product `units × price ÷ 1 000 000` is rounded half away from
/// zero to the currency's minor unit, so 3.333333 units at 1.50 (4.9999995)
/// is worth 5.00 and 0.5 units at 0.01 is worth 0.01. Each holding is
/// rounded on its own before holdings are added together.
Money valueOfUnits(int units, Money unitPrice) =>
    Money(scaleHalfUp(units, unitPrice.minor, unitsScale), unitPrice.currency);

/// One security held in an investment or superannuation account.
@immutable
class Holding {
  const Holding({
    required this.id,
    required this.securityCode,
    required this.name,
    required this.accountId,
  });

  final String id;

  /// Exchange code or fund identifier, such as `VAS`; prices are keyed by it.
  final String securityCode;
  final String name;

  /// The investment account the holding belongs to.
  final String accountId;
}

enum HoldingEventType { buy, sell, split }

enum HoldingError {
  insufficientUnits('INSUFFICIENT_UNITS');

  const HoldingError(this.code);
  final String code;
}

class HoldingException implements Exception {
  HoldingException(this.code, [this.detail]);
  final HoldingError code;
  final String? detail;

  @override
  String toString() =>
      'HoldingException(${code.code}${detail == null ? '' : ': $detail'})';
}

/// A change to the units of a holding.
///
/// Buys and sells carry a positive quantity in micro-units. A split
/// multiplies the units held by [splitNumerator] / [splitDenominator]: a
/// two-for-one split is 2/1 and a one-for-three consolidation is 1/3.
@immutable
class HoldingEvent {
  HoldingEvent._({
    required this.id,
    required this.holdingId,
    required this.date,
    required this.type,
    this.units,
    this.splitNumerator,
    this.splitDenominator,
  });

  factory HoldingEvent.buy({
    required String id,
    required String holdingId,
    required LocalDate date,
    required int units,
  }) => HoldingEvent._(
    id: id,
    holdingId: holdingId,
    date: date,
    type: HoldingEventType.buy,
    units: _positive(units, 'units'),
  );

  factory HoldingEvent.sell({
    required String id,
    required String holdingId,
    required LocalDate date,
    required int units,
  }) => HoldingEvent._(
    id: id,
    holdingId: holdingId,
    date: date,
    type: HoldingEventType.sell,
    units: _positive(units, 'units'),
  );

  factory HoldingEvent.split({
    required String id,
    required String holdingId,
    required LocalDate date,
    required int numerator,
    required int denominator,
  }) => HoldingEvent._(
    id: id,
    holdingId: holdingId,
    date: date,
    type: HoldingEventType.split,
    splitNumerator: _positive(numerator, 'numerator'),
    splitDenominator: _positive(denominator, 'denominator'),
  );

  final String id;
  final String holdingId;
  final LocalDate date;
  final HoldingEventType type;

  /// Micro-units bought or sold; null for a split.
  final int? units;
  final int? splitNumerator;
  final int? splitDenominator;

  static int _positive(int value, String name) {
    if (value <= 0) throw ArgumentError.value(value, name, 'must be positive');
    return value;
  }
}

/// Micro-units of [holdingId] held at the end of [asOf] (all events when
/// null).
///
/// Events apply in date order; events on the same date keep the order
/// given. A split's result is rounded half away from zero to a whole
/// micro-unit. Selling more units than are held throws a
/// [HoldingException].
int unitsHeld(
  Iterable<HoldingEvent> events, {
  required String holdingId,
  LocalDate? asOf,
}) {
  final relevant = [
    for (final e in events)
      if (e.holdingId == holdingId && (asOf == null || e.date <= asOf)) e,
  ];
  final ordered = List<int>.generate(relevant.length, (i) => i)
    ..sort((a, b) {
      final byDate = relevant[a].date.compareTo(relevant[b].date);
      return byDate != 0 ? byDate : a.compareTo(b);
    });
  var units = 0;
  for (final index in ordered) {
    final event = relevant[index];
    switch (event.type) {
      case HoldingEventType.buy:
        units += event.units!;
      case HoldingEventType.sell:
        if (event.units! > units) {
          throw HoldingException(
            HoldingError.insufficientUnits,
            '${event.id} sells ${formatUnits(event.units!)} of '
            '${formatUnits(units)}',
          );
        }
        units -= event.units!;
      case HoldingEventType.split:
        units = scaleHalfUp(
          units,
          event.splitNumerator!,
          event.splitDenominator!,
        );
    }
  }
  return units;
}

/// The price of one whole unit of a security on a date.
@immutable
class SecurityPrice {
  const SecurityPrice({
    required this.securityCode,
    required this.date,
    required this.price,
  });

  final String securityCode;
  final LocalDate date;

  /// Price per whole unit, in minor units of the workspace currency.
  final Money price;
}

/// Dated unit prices, looked up by security code. A later entry for the
/// same security and date replaces an earlier one (a correction).
class PriceBook {
  PriceBook(Iterable<SecurityPrice> prices) {
    final byCode = <String, Map<LocalDate, SecurityPrice>>{};
    for (final price in prices) {
      byCode.putIfAbsent(price.securityCode, () => {})[price.date] = price;
    }
    for (final entry in byCode.entries) {
      _prices[entry.key] = entry.value.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
    }
  }

  final _prices = <String, List<SecurityPrice>>{};

  /// The most recent price on or before [asOf], or null when none exists.
  SecurityPrice? latest(String securityCode, LocalDate asOf) {
    SecurityPrice? found;
    for (final price in _prices[securityCode] ?? const <SecurityPrice>[]) {
      if (price.date > asOf) break;
      found = price;
    }
    return found;
  }
}

/// One holding's units, price and value on a date.
@immutable
class HoldingValuation {
  const HoldingValuation({
    required this.holding,
    required this.asOf,
    required this.units,
    required this.price,
    required this.value,
  });

  final Holding holding;
  final LocalDate asOf;

  /// Micro-units held at the end of [asOf].
  final int units;

  /// The price used, which may be dated before [asOf]; null when none.
  final SecurityPrice? price;

  /// Units times price (see [valueOfUnits]); zero when no units are held,
  /// and null when units are held but no price is known.
  final Money? value;
}

/// The holdings of one account valued on a date.
@immutable
class PortfolioValuation {
  PortfolioValuation({
    required this.accountId,
    required this.asOf,
    required List<HoldingValuation> holdings,
    required this.total,
  }) : holdings = List.unmodifiable(holdings);

  final String accountId;
  final LocalDate asOf;
  final List<HoldingValuation> holdings;

  /// Sum of the holdings that have a value.
  final Money total;

  /// Holdings with units but no price; they are left out of [total].
  List<HoldingValuation> get unpriced => [
    for (final h in holdings)
      if (h.value == null) h,
  ];

  bool get isComplete => holdings.every((h) => h.value != null);
}

/// Values the holdings of [accountId] at the end of [asOf], in the order
/// [holdings] lists them. Holdings of other accounts are ignored.
PortfolioValuation valuePortfolio({
  required String accountId,
  required Currency currency,
  required Iterable<Holding> holdings,
  required Iterable<HoldingEvent> events,
  required PriceBook prices,
  required LocalDate asOf,
}) {
  var total = Money.zero(currency);
  final valued = <HoldingValuation>[];
  for (final holding in holdings) {
    if (holding.accountId != accountId) continue;
    final units = unitsHeld(events, holdingId: holding.id, asOf: asOf);
    final price = prices.latest(holding.securityCode, asOf);
    final value = units == 0
        ? Money.zero(currency)
        : price == null
        ? null
        : valueOfUnits(units, price.price);
    if (value != null) total += value;
    valued.add(
      HoldingValuation(
        holding: holding,
        asOf: asOf,
        units: units,
        price: price,
        value: value,
      ),
    );
  }
  return PortfolioValuation(
    accountId: accountId,
    asOf: asOf,
    holdings: valued,
    total: total,
  );
}

/// [valuePortfolio] for each of [dates], in the order given.
List<PortfolioValuation> valuationHistory({
  required String accountId,
  required Currency currency,
  required Iterable<Holding> holdings,
  required Iterable<HoldingEvent> events,
  required PriceBook prices,
  required Iterable<LocalDate> dates,
}) => [
  for (final date in dates)
    valuePortfolio(
      accountId: accountId,
      currency: currency,
      holdings: holdings,
      events: events,
      prices: prices,
      asOf: date,
    ),
];

/// A suggested balance adjustment bringing an investment account's
/// recorded balance into line with its holdings. It changes nothing: the
/// user confirms [draft] before it becomes a journal.
@immutable
class ValuationAdjustmentProposal {
  const ValuationAdjustmentProposal({
    required this.valuation,
    required this.recordedBalance,
    required this.draft,
  });

  final PortfolioValuation valuation;

  /// The account's posted balance at the end of the valuation date.
  final Money recordedBalance;

  /// The adjustment to confirm, or null when the balance already matches
  /// or a holding has no price.
  final TransactionDraft? draft;

  String get accountId => valuation.accountId;
  LocalDate get asOf => valuation.asOf;
  Money get valuedBalance => valuation.total;
  Money get difference => valuation.total - recordedBalance;
  bool get isComplete => valuation.isComplete;
}

/// Compares [valuation] with the posted balance of its account and
/// proposes an adjustment draft for the difference, dated on the valuation
/// date. Only investment and superannuation accounts can be valued.
ValuationAdjustmentProposal proposeValuationAdjustment(
  LedgerProjection ledger,
  PortfolioValuation valuation, {
  String? draftId,
}) {
  final type = ledger.chart.account(valuation.accountId).type;
  if (type != AccountType.investment && type != AccountType.superannuation) {
    throw ArgumentError.value(
      valuation.accountId,
      'accountId',
      'not an investment or superannuation account',
    );
  }
  final recorded = ledger.displayBalance(
    valuation.accountId,
    asOf: valuation.asOf,
  );
  final difference = valuation.total - recorded;
  return ValuationAdjustmentProposal(
    valuation: valuation,
    recordedBalance: recorded,
    draft: difference.isZero || !valuation.isComplete
        ? null
        : TransactionDraft(
            id: draftId,
            type: TransactionType.adjustment,
            accountId: valuation.accountId,
            amount: difference,
            effectiveDate: valuation.asOf,
            notes: 'Holdings valuation on ${valuation.asOf}',
          ),
  );
}

/// Month-end values of holdings per account across [range], keyed like
/// `netWorthHistory` (the month end, or the range end for a partial last
/// month) so the two reports can be shown side by side.
///
/// There is one money column per account in [chart] that has holdings and
/// is included in net worth, in chart order, then `total`, then the
/// `unpriced` count of holdings that had units but no price on that date
/// (those are left out of the amounts).
Report holdingsValuationHistory(
  Chart chart, {
  required Iterable<Holding> holdings,
  required Iterable<HoldingEvent> events,
  required PriceBook prices,
  required DateRange range,
  bool includesUnsyncedChanges = false,
}) {
  final held = holdings.toList();
  final accounts = [
    for (final account in chart.accounts)
      if (account.includeInNetWorth &&
          held.any((h) => h.accountId == account.id))
        account,
  ];
  final dates = [for (final month in range.months()) month.end];
  final histories = {
    for (final account in accounts)
      account.id: valuationHistory(
        accountId: account.id,
        currency: chart.currency,
        holdings: held,
        events: events,
        prices: prices,
        dates: dates,
      ),
  };
  return Report(
    title: 'Holdings value',
    keyLabel: 'Date',
    range: range,
    includesUnsyncedChanges: includesUnsyncedChanges,
    columns: [
      for (final account in accounts) ReportColumn(account.id, account.name),
      const ReportColumn('total', 'Total'),
      const ReportColumn(
        'unpriced',
        'Holdings without a price',
        kind: ReportValueKind.count,
      ),
    ],
    rows: [
      for (var i = 0; i < dates.length; i++)
        ReportRow(
          key: dates[i].toString(),
          label: dates[i].toString(),
          amounts: {
            for (final account in accounts)
              account.id: histories[account.id]![i].total,
            'total': accounts.fold(
              Money.zero(chart.currency),
              (sum, account) => sum + histories[account.id]![i].total,
            ),
          },
          counts: {
            'unpriced': accounts.fold(
              0,
              (sum, account) => sum + histories[account.id]![i].unpriced.length,
            ),
          },
        ),
    ],
  );
}
