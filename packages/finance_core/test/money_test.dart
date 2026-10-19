import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;

  group('Money arithmetic', () {
    test('adds and subtracts in minor units', () {
      final a = Money(10347, aud);
      final b = Money(8000, aud);
      expect((a - b).minor, 2347);
      expect((a + b).minor, 18347);
      expect((-a).minor, -10347);
    });

    test('rejects mixed currencies', () {
      expect(
        () => Money(1, aud) + Money(1, const Currency('NZD', 2)),
        throwsA(isA<CurrencyMismatchException>()),
      );
    });

    test('rejects values beyond the supported magnitude', () {
      expect(
        () => Money(maxMinorMagnitude + 1, aud),
        throwsA(isA<MoneyRangeException>()),
      );
      final max = Money(maxMinorMagnitude, aud);
      expect(() => max + Money(1, aud), throwsA(isA<MoneyRangeException>()));
    });

    test('equality is by value and currency', () {
      expect(Money(5, aud), Money(5, aud));
      expect(Money(5, aud) == Money(5, const Currency('NZD', 2)), isFalse);
    });

    test('formats as a plain decimal string', () {
      expect(Money(-10347, aud).toDecimalString(), '-103.47');
      expect(Money(5, aud).toDecimalString(), '0.05');
      expect(Money(7, const Currency('JPY', 0)).toDecimalString(), '7');
    });
  });

  group('Money parsing', () {
    test('parses decimal text exactly', () {
      expect(Money.parse('103.47', aud).minor, 10347);
      expect(Money.parse('-0.5', aud).minor, -50);
      expect(Money.parse('1,234.50', aud).minor, 123450);
      expect(Money.parse('12', aud).minor, 1200);
    });

    test('rejects excess precision rather than rounding', () {
      expect(() => Money.parse('1.005', aud), throwsFormatException);
    });

    test('supports a comma decimal separator when requested', () {
      expect(Money.parse('1.234,56', aud, decimalSeparator: ',').minor, 123456);
    });
  });

  group('allocateByWeights', () {
    test('distributes the rounding remainder deterministically', () {
      expect(allocateByWeights(100, [1, 1, 1]), [34, 33, 33]);
      expect(allocateByWeights(-100, [1, 1, 1]), [-34, -33, -33]);
    });

    test('parts always sum to the total', () {
      for (var total = -500; total <= 500; total += 37) {
        final parts = allocateByWeights(total, [5000, 3000, 2000]);
        expect(parts.reduce((a, b) => a + b), total);
      }
    });

    test('splits a fortnightly income by 50/30/20 exactly', () {
      expect(allocateByWeights(312345, [5000, 3000, 2000]), [
        156173,
        93703,
        62469,
      ]);
    });
  });
}
