import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  group('normaliseText', () {
    test(
      'lower-cases and collapses everything but ASCII letters and digits',
      () {
        expect(
          normaliseText('  WOOLWORTHS  1234,  Sydney!! '),
          'woolworths 1234 sydney',
        );
        expect(normaliseText('Café—Déjà'), 'caf d j');
        expect(normaliseText('***'), '');
      },
    );
  });

  group('normaliseMerchant', () {
    test('drops legal suffixes, locations, processor prefixes and numbers', () {
      expect(
        normaliseMerchant('WOOLWORTHS 1234 SYDNEY NSW AU'),
        'woolworths sydney',
      );
      expect(
        normaliseMerchant('Coles Supermarkets Pty Ltd'),
        'coles supermarkets',
      );
      expect(normaliseMerchant('SQ *BEAN THERE CAFE'), 'bean there cafe');
      expect(normaliseMerchant('VISA PURCHASE BUNNINGS 456'), 'bunnings');
      expect(normaliseMerchant('amazon.com.au'), 'amazon');
    });

    test('falls back to plain normalisation when everything is noise', () {
      expect(normaliseMerchant('PTY LTD 123'), 'pty ltd 123');
    });
  });

  group('merchantSimilarity', () {
    test('is 1 for the same normalised merchant', () {
      expect(merchantSimilarity('Woolworths', 'WOOLWORTHS 1234'), 1.0);
    });

    test(
      'is high when one name contains the other or the first word matches',
      () {
        expect(
          merchantSimilarity('Bunnings', 'Bunnings Warehouse'),
          greaterThanOrEqualTo(0.9),
        );
        expect(
          merchantSimilarity('Woolworths Metro', 'WOOLWORTHS 1234 SYDNEY'),
          greaterThanOrEqualTo(0.8),
        );
      },
    );

    test('is low for unrelated merchants and zero for empty names', () {
      expect(
        merchantSimilarity('Coles', 'Shell Coles Express'),
        greaterThan(0.5),
      );
      expect(merchantSimilarity('Bunnings', 'Officeworks'), lessThan(0.3));
      expect(merchantSimilarity('', 'Officeworks'), 0);
    });
  });
}
