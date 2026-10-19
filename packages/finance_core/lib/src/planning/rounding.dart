/// Computes `value × numerator ÷ denominator` exactly and rounds half away
/// from zero (the same result as Java's `RoundingMode.HALF_UP`).
///
/// The product is formed with [BigInt], so large amounts multiplied by
/// basis points or annual factors cannot overflow before division.
int scaleHalfUp(int value, int numerator, int denominator) {
  if (denominator <= 0) {
    throw ArgumentError.value(denominator, 'denominator', 'must be positive');
  }
  final product = BigInt.from(value) * BigInt.from(numerator);
  final magnitude = product.abs();
  final divisor = BigInt.from(denominator);
  var quotient = magnitude ~/ divisor;
  if ((magnitude % divisor) * BigInt.two >= divisor) {
    quotient += BigInt.one;
  }
  return (product.isNegative ? -quotient : quotient).toInt();
}
