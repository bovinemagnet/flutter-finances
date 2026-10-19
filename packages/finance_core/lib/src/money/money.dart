import 'package:meta/meta.dart';

/// Largest supported magnitude in minor units (just under one quadrillion).
///
/// Keeping amounts well inside the signed 64-bit range means sums of many
/// postings cannot silently overflow before range validation catches them.
const int maxMinorMagnitude = 999999999999999;

/// An ISO 4217 currency with an explicit minor-unit exponent.
@immutable
class Currency {
  const Currency(this.code, this.exponent)
    : assert(exponent >= 0 && exponent <= 4);

  static const aud = Currency('AUD', 2);

  final String code;
  final int exponent;

  @override
  bool operator ==(Object other) =>
      other is Currency && other.code == code && other.exponent == exponent;

  @override
  int get hashCode => Object.hash(code, exponent);

  @override
  String toString() => code;
}

class CurrencyMismatchException implements Exception {
  CurrencyMismatchException(this.left, this.right);
  final Currency left;
  final Currency right;

  @override
  String toString() => 'Currency mismatch: $left and $right';
}

class MoneyRangeException implements Exception {
  MoneyRangeException(this.minor);
  final int minor;

  @override
  String toString() => 'Amount $minor is outside the supported range';
}

/// An exact amount of money held as signed minor units.
@immutable
class Money implements Comparable<Money> {
  Money(this.minor, this.currency) {
    checkMinorRange(minor);
  }

  Money.zero(this.currency) : minor = 0;

  /// Parses plain decimal text such as `-1,234.50` without rounding.
  ///
  /// Grouping separators are ignored. Text with more fractional digits than
  /// the currency exponent is rejected rather than rounded.
  factory Money.parse(
    String text,
    Currency currency, {
    String decimalSeparator = '.',
  }) {
    return Money(
      parseMinor(text, currency.exponent, decimalSeparator: decimalSeparator),
      currency,
    );
  }

  final int minor;
  final Currency currency;

  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;
  bool get isPositive => minor > 0;

  Money abs() => isNegative ? -this : this;

  Money operator +(Money other) {
    _checkCurrency(other);
    return Money(minor + other.minor, currency);
  }

  Money operator -(Money other) {
    _checkCurrency(other);
    return Money(minor - other.minor, currency);
  }

  Money operator -() => Money(-minor, currency);

  bool operator <(Money other) => compareTo(other) < 0;
  bool operator >(Money other) => compareTo(other) > 0;
  bool operator <=(Money other) => compareTo(other) <= 0;
  bool operator >=(Money other) => compareTo(other) >= 0;

  @override
  int compareTo(Money other) {
    _checkCurrency(other);
    return minor.compareTo(other.minor);
  }

  /// Splits this amount across [weights] exactly; see [allocateByWeights].
  List<Money> allocate(List<int> weights) => allocateByWeights(
    minor,
    weights,
  ).map((part) => Money(part, currency)).toList();

  String toDecimalString() => formatMinor(minor, currency.exponent);

  void _checkCurrency(Money other) {
    if (other.currency != currency) {
      throw CurrencyMismatchException(currency, other.currency);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => '${toDecimalString()} $currency';
}

void checkMinorRange(int minor) {
  if (minor > maxMinorMagnitude || minor < -maxMinorMagnitude) {
    throw MoneyRangeException(minor);
  }
}

/// Parses decimal text to minor units for a currency [exponent].
int parseMinor(String text, int exponent, {String decimalSeparator = '.'}) {
  final grouping = decimalSeparator == '.' ? ',' : '.';
  var cleaned = text.trim().replaceAll(grouping, '').replaceAll(' ', '');
  var negative = false;
  if (cleaned.startsWith('-')) {
    negative = true;
    cleaned = cleaned.substring(1);
  } else if (cleaned.startsWith('+')) {
    cleaned = cleaned.substring(1);
  }
  final parts = cleaned.split(decimalSeparator);
  if (parts.length > 2 ||
      !RegExp(r'^\d+$').hasMatch(parts[0].isEmpty ? '0' : parts[0]) ||
      (parts.length == 2 && !RegExp(r'^\d+$').hasMatch(parts[1]))) {
    throw FormatException('Not a decimal amount', text);
  }
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > exponent) {
    throw FormatException('More than $exponent decimal places', text);
  }
  if (whole.length > 16) {
    throw FormatException('Amount too large', text);
  }
  final minor =
      int.parse(whole) * _pow10(exponent) +
      (fraction.isEmpty ? 0 : int.parse(fraction.padRight(exponent, '0')));
  final signed = negative ? -minor : minor;
  checkMinorRange(signed);
  return signed;
}

String formatMinor(int minor, int exponent) {
  final sign = minor < 0 ? '-' : '';
  final digits = minor.abs().toString().padLeft(exponent + 1, '0');
  if (exponent == 0) return '$sign$digits';
  final cut = digits.length - exponent;
  return '$sign${digits.substring(0, cut)}.${digits.substring(cut)}';
}

int _pow10(int exponent) {
  var value = 1;
  for (var i = 0; i < exponent; i++) {
    value *= 10;
  }
  return value;
}

/// Splits [total] in proportion to non-negative integer [weights] exactly.
///
/// Uses the largest remainder method on the magnitude: each part receives the
/// floor of its share, then the leftover units go to the largest fractional
/// remainders, ties going to the lower index. The sign of [total] is then
/// reapplied, so the parts always sum to [total].
List<int> allocateByWeights(int total, List<int> weights) {
  if (weights.isEmpty || weights.any((w) => w < 0)) {
    throw ArgumentError.value(weights, 'weights', 'must be non-negative');
  }
  final weightSum = weights.fold<int>(0, (a, b) => a + b);
  if (weightSum == 0) {
    throw ArgumentError.value(weights, 'weights', 'must not all be zero');
  }
  final magnitude = BigInt.from(total.abs());
  final sum = BigInt.from(weightSum);
  final parts = <int>[];
  final remainders = <BigInt>[];
  for (final weight in weights) {
    final product = magnitude * BigInt.from(weight);
    parts.add((product ~/ sum).toInt());
    remainders.add(product % sum);
  }
  var leftover = total.abs() - parts.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final byRemainder = remainders[b].compareTo(remainders[a]);
      return byRemainder != 0 ? byRemainder : a.compareTo(b);
    });
  for (final index in order) {
    if (leftover == 0) break;
    parts[index] += 1;
    leftover -= 1;
  }
  return total < 0 ? parts.map((p) => -p).toList() : parts;
}
