import 'package:finance_core/finance_core.dart';
import 'package:intl/intl.dart';

const _symbols = {'AUD': r'$', 'NZD': r'$', 'USD': r'$', 'GBP': '£', 'EUR': '€'};

/// Formats money from integer minor units, never via floating point.
///
/// [hidden] masks the amount, used in notifications and privacy mode.
String formatMoney(Money money,
    {bool signed = false, bool hidden = false, String locale = 'en_AU'}) {
  final symbol = _symbols[money.currency.code] ?? '${money.currency.code} ';
  if (hidden) return '$symbol•••';
  final text = formatMinor(money.minor.abs(), money.currency.exponent);
  final dot = text.indexOf('.');
  final whole = int.parse(dot < 0 ? text : text.substring(0, dot));
  final fraction = dot < 0 ? '' : text.substring(dot);
  final grouped = NumberFormat.decimalPattern(locale).format(whole);
  final sign = money.isNegative ? '-' : (signed && money.isPositive ? '+' : '');
  return '$sign$symbol$grouped$fraction';
}

String formatDate(LocalDate date, {String locale = 'en_AU'}) =>
    DateFormat('d MMM y', locale).format(DateTime(date.year, date.month, date.day));

String formatShortDate(LocalDate date, {String locale = 'en_AU'}) =>
    DateFormat('dd/MM/yyyy', locale)
        .format(DateTime(date.year, date.month, date.day));
