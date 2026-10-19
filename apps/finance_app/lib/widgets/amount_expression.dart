import 'package:finance_core/finance_core.dart';

final _token = RegExp(r'\s*([+\-x×*]|[0-9][0-9,]*(?:\.[0-9]+)?|\.[0-9]+)\s*');

/// Evaluates a calculator entry such as `12.50+3.25` or `3 x 4.10` exactly.
///
/// Supports addition, subtraction and multiplication by a whole quantity.
/// Currency symbols and spaces are ignored; excess decimal places are
/// rejected rather than rounded.
Money evaluateAmountExpression(String text, Currency currency) {
  final cleaned = text.replaceAll(RegExp(r'[$£€\s]'), '');
  if (cleaned.isEmpty) throw FormatException('Enter an amount', text);
  final tokens = <String>[];
  var index = 0;
  while (index < cleaned.length) {
    final match = _token.matchAsPrefix(cleaned, index);
    if (match == null) throw FormatException('Unexpected character', text, index);
    tokens.add(match.group(1)!);
    index = match.end;
  }

  // Terms separated by + or -, each term a product of factors.
  var total = Money.zero(currency);
  var sign = 1;
  var position = 0;
  bool isOperator(String t) => '+-x×*'.contains(t) && t.length == 1;
  if (tokens.first == '-') {
    sign = -1;
    position = 1;
  }
  while (position < tokens.length) {
    final factors = <String>[];
    while (true) {
      if (position >= tokens.length || isOperator(tokens[position])) {
        throw FormatException('Incomplete expression', text);
      }
      factors.add(tokens[position++]);
      if (position < tokens.length && 'x×*'.contains(tokens[position])) {
        position++;
        continue;
      }
      break;
    }
    final term = _product(factors, currency, text);
    total = sign > 0 ? total + term : total - term;
    if (position < tokens.length) {
      sign = tokens[position] == '-' ? -1 : 1;
      position++;
      if (position >= tokens.length) {
        throw FormatException('Incomplete expression', text);
      }
    }
  }
  return total;
}

Money _product(List<String> factors, Currency currency, String source) {
  if (factors.length == 1) return Money.parse(factors.single, currency);
  final amounts = factors.where((f) => f.contains('.')).toList();
  if (amounts.length > 1) {
    throw FormatException('Multiply an amount by a whole quantity', source);
  }
  final amountText = amounts.isEmpty ? factors.first : amounts.single;
  var result = Money.parse(amountText, currency);
  var usedAmount = false;
  for (final factor in factors) {
    if (!usedAmount && factor == amountText) {
      usedAmount = true;
      continue;
    }
    final quantity = int.parse(factor.replaceAll(',', ''));
    result = Money(result.minor * quantity, currency);
  }
  return result;
}
