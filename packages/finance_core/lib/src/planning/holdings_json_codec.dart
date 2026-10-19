import '../money/money.dart';
import '../time/local_date.dart';
import 'holdings.dart';

// JSON formats for holdings, holding events and security prices. Units are
// integer micro-units in `unitsMicro`, prices are integer minor units of
// the workspace currency in `priceMinor`, dates are ISO `YYYY-MM-DD`
// strings and enums use their names.

Map<String, Object?> holdingToJson(Holding holding) => {
  'id': holding.id,
  'securityCode': holding.securityCode,
  'name': holding.name,
  'accountId': holding.accountId,
};

Holding holdingFromJson(Map<String, Object?> json) => Holding(
  id: json['id'] as String,
  securityCode: json['securityCode'] as String,
  name: json['name'] as String,
  accountId: json['accountId'] as String,
);

Map<String, Object?> holdingEventToJson(HoldingEvent event) => {
  'id': event.id,
  'holdingId': event.holdingId,
  'date': event.date.toString(),
  'type': event.type.name,
  'unitsMicro': event.units,
  'splitNumerator': event.splitNumerator,
  'splitDenominator': event.splitDenominator,
};

HoldingEvent holdingEventFromJson(Map<String, Object?> json) {
  final id = json['id'] as String;
  final holdingId = json['holdingId'] as String;
  final date = LocalDate.parse(json['date'] as String);
  return switch (HoldingEventType.values.byName(json['type'] as String)) {
    HoldingEventType.buy => HoldingEvent.buy(
      id: id,
      holdingId: holdingId,
      date: date,
      units: json['unitsMicro'] as int,
    ),
    HoldingEventType.sell => HoldingEvent.sell(
      id: id,
      holdingId: holdingId,
      date: date,
      units: json['unitsMicro'] as int,
    ),
    HoldingEventType.split => HoldingEvent.split(
      id: id,
      holdingId: holdingId,
      date: date,
      numerator: json['splitNumerator'] as int,
      denominator: json['splitDenominator'] as int,
    ),
  };
}

Map<String, Object?> securityPriceToJson(SecurityPrice price) => {
  'securityCode': price.securityCode,
  'date': price.date.toString(),
  'priceMinor': price.price.minor,
};

SecurityPrice securityPriceFromJson(
  Map<String, Object?> json,
  Currency currency,
) => SecurityPrice(
  securityCode: json['securityCode'] as String,
  date: LocalDate.parse(json['date'] as String),
  price: Money(json['priceMinor'] as int, currency),
);
