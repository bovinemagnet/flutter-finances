import 'package:finance_app/app/breakpoints.dart';
import 'package:finance_app/format/formatters.dart';
import 'package:finance_app/widgets/amount_expression.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  const aud = Currency.aud;
  setUpAll(() => initializeDateFormatting('en_AU'));

  group('windowClassFor', () {
    test('uses width breakpoints at 600 and 1024 logical pixels', () {
      expect(windowClassFor(599.9), WindowClass.compact);
      expect(windowClassFor(600), WindowClass.medium);
      expect(windowClassFor(1023.9), WindowClass.medium);
      expect(windowClassFor(1024), WindowClass.expanded);
    });
  });

  group('formatMoney', () {
    test('formats Australian dollars exactly without floating point', () {
      expect(formatMoney(Money(123456789, aud)), r'$1,234,567.89');
      expect(formatMoney(Money(-5, aud)), r'-$0.05');
      expect(
        formatMoney(Money(999999999999999, aud)),
        r'$9,999,999,999,999.99',
      );
    });

    test('can show an explicit sign and hide amounts', () {
      expect(formatMoney(Money(1000, aud), signed: true), r'+$10.00');
      expect(formatMoney(Money(1000, aud), hidden: true), r'$•••');
    });

    test('formats Australian dates', () {
      expect(formatDate(LocalDate(2026, 7, 1)), '1 July 2026');
      expect(formatDate(LocalDate(2026, 8, 3)), '3 Aug 2026');
      expect(formatShortDate(LocalDate(2026, 7, 1)), '01/07/2026');
    });
  });

  group('evaluateAmountExpression', () {
    test('evaluates sums and differences exactly', () {
      expect(evaluateAmountExpression('12.50+3.25', aud), Money(1575, aud));
      expect(evaluateAmountExpression('100 - 0.01', aud), Money(9999, aud));
      expect(evaluateAmountExpression(r'$1,200', aud), Money(120000, aud));
    });

    test('multiplies by a whole quantity', () {
      expect(evaluateAmountExpression('3 x 4.10', aud), Money(1230, aud));
      expect(evaluateAmountExpression('4.10*3', aud), Money(1230, aud));
    });

    test('rejects malformed input', () {
      expect(
        () => evaluateAmountExpression('1.234', aud),
        throwsFormatException,
      );
      expect(() => evaluateAmountExpression('5+', aud), throwsFormatException);
      expect(() => evaluateAmountExpression('', aud), throwsFormatException);
    });
  });
}
