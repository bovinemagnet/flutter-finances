import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

const aud = Currency.aud;

CsvMapping signedMapping({
  DebitSign debitSign = DebitSign.negative,
  String decimalSeparator = '.',
  String delimiter = ',',
  String dateFormat = 'dd/MM/yyyy',
}) => CsvMapping(
  id: 'm1',
  name: 'Everyday bank',
  accountId: 'bank',
  dateColumn: const CsvColumn.header('Date'),
  dateFormat: dateFormat,
  descriptionColumn: const CsvColumn.header('Description'),
  amountColumn: const CsvColumn.header('Amount'),
  referenceColumn: const CsvColumn.header('Reference'),
  debitSign: debitSign,
  decimalSeparator: decimalSeparator,
  delimiter: delimiter,
);

void main() {
  group('decodeText', () {
    test('decodes UTF-8 with and without a byte order mark', () {
      final plain = Uint8List.fromList(utf8.encode('Café,1'));
      final bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...plain]);
      expect(decodeText(plain, TextEncoding.utf8), 'Café,1');
      expect(decodeText(bom, TextEncoding.utf8), 'Café,1');
    });

    test('decodes Windows-1252 and Latin-1 single-byte text', () {
      final bytes = Uint8List.fromList([
        0x43,
        0x61,
        0x66,
        0xE9,
        0x20,
        0x80,
        0x92,
      ]);
      expect(decodeText(bytes, TextEncoding.windows1252), 'Café €’');
      expect(decodeText(bytes, TextEncoding.latin1), 'Café \u0080\u0092');
    });

    test('rejects malformed UTF-8 rather than guessing', () {
      final bytes = Uint8List.fromList([0x43, 0xE9, 0x2C]);
      expect(
        () => decodeText(bytes, TextEncoding.utf8),
        throwsA(isA<TextDecodingException>()),
      );
    });

    test('detects encoding from a BOM or UTF-8 validity', () {
      expect(
        detectEncoding(Uint8List.fromList(utf8.encode('Café'))),
        TextEncoding.utf8,
      );
      expect(
        detectEncoding(Uint8List.fromList([0x43, 0xE9])),
        TextEncoding.windows1252,
      );
    });
  });

  group('readCsv', () {
    test('follows RFC 4180 quoting, escaped quotes and embedded newlines', () {
      final result = readCsv('a,"b, c","say ""hi"""\r\n"multi\nline",2,3\n');
      expect(result.errors, isEmpty);
      expect(result.records.map((r) => r.fields).toList(), [
        ['a', 'b, c', 'say "hi"'],
        ['multi\nline', '2', '3'],
      ]);
      expect(result.records.map((r) => r.number).toList(), [1, 2]);
    });

    test('supports other delimiters, CR line endings and no final newline', () {
      final result = readCsv('a;b\rc;"d;e"', delimiter: ';');
      expect(result.records.map((r) => r.fields).toList(), [
        ['a', 'b'],
        ['c', 'd;e'],
      ]);
    });

    test('skips blank lines but keeps counting record numbers', () {
      final result = readCsv('a\n\nb\n');
      expect(result.records.map((r) => r.number).toList(), [1, 3]);
    });

    test('reports an unterminated quote with its starting record', () {
      final result = readCsv('a,b\n"open,c\n');
      expect(result.records.map((r) => r.fields).toList(), [
        ['a', 'b'],
      ]);
      expect(result.errors.single.row, 2);
      expect(result.errors.single.code, ImportErrorCode.unterminatedQuote);
    });

    test('keeps stray quotes inside unquoted fields literally', () {
      expect(readCsv('5" screen,1').records.single.fields, ['5" screen', '1']);
    });
  });

  group('parseDate', () {
    test('parses common bank formats', () {
      expect(
        parseDateWithFormat('01/07/2026', 'dd/MM/yyyy'),
        LocalDate(2026, 7, 1),
      );
      expect(parseDateWithFormat('1/7/26', 'd/M/yy'), LocalDate(2026, 7, 1));
      expect(
        parseDateWithFormat('2026-07-01', 'yyyy-MM-dd'),
        LocalDate(2026, 7, 1),
      );
      expect(
        parseDateWithFormat('07/01/2026', 'MM/dd/yyyy'),
        LocalDate(2026, 7, 1),
      );
      expect(
        parseDateWithFormat('01-Jul-2026', 'dd-MMM-yyyy'),
        LocalDate(2026, 7, 1),
      );
      expect(
        parseDateWithFormat('01 jul 2026 14:22', 'dd MMM yyyy'),
        LocalDate(2026, 7, 1),
      );
    });

    test('returns null for malformed or impossible dates', () {
      expect(parseDateWithFormat('31/02/2026', 'dd/MM/yyyy'), isNull);
      expect(parseDateWithFormat('2026-07-01', 'dd/MM/yyyy'), isNull);
      expect(parseDateWithFormat('01-Jux-2026', 'dd-MMM-yyyy'), isNull);
    });
  });

  group('parseCsvRows', () {
    test('parses signed amounts with references and row numbers', () {
      const text =
          'Date,Description,Amount,Reference\n'
          '01/07/2026,"WOOLWORTHS 1234, SYDNEY",-63.25,R1\n'
          '02/07/2026,SALARY ACME,2500.00,\n';
      final result = parseCsvRows(text, signedMapping(), aud);
      expect(result.errors, isEmpty);
      expect(result.rows.length, 2);
      final first = result.rows.first;
      expect(first.rowNumber, 2);
      expect(first.date, LocalDate(2026, 7, 1));
      expect(first.amount, Money(-6325, aud));
      expect(first.description, 'WOOLWORTHS 1234, SYDNEY');
      expect(first.reference, 'R1');
      expect(first.raw, [
        '01/07/2026',
        'WOOLWORTHS 1234, SYDNEY',
        '-63.25',
        'R1',
      ]);
      expect(result.rows.last.reference, isNull);
    });

    test('flips signs when debits are shown as positive numbers', () {
      const text =
          'Date,Description,Amount,Reference\n01/07/2026,Card purchase,63.25,\n';
      final result = parseCsvRows(
        text,
        signedMapping(debitSign: DebitSign.positive),
        aud,
      );
      expect(result.rows.single.amount.minor, -6325);
    });

    test('combines separate debit and credit columns', () {
      final mapping = CsvMapping(
        id: 'm2',
        name: 'Card',
        accountId: 'card',
        hasHeader: false,
        dateColumn: const CsvColumn.index(0),
        dateFormat: 'yyyy-MM-dd',
        descriptionColumn: const CsvColumn.index(1),
        debitColumn: const CsvColumn.index(2),
        creditColumn: const CsvColumn.index(3),
      );
      const text =
          '2026-07-01,Coffee,4.50,\n'
          '2026-07-02,Refund,,10.00\n'
          '2026-07-03,Both,1.00,2.00\n'
          '2026-07-04,Neither,,\n'
          '2026-07-05,Zero padded,0.00,7.00\n';
      final result = parseCsvRows(text, mapping, aud);
      expect(result.rows.map((r) => r.amount.minor).toList(), [
        -450,
        1000,
        700,
      ]);
      expect(result.rows.first.rowNumber, 1);
      expect(result.errors.map((e) => (e.row, e.code)).toList(), [
        (3, ImportErrorCode.bothDebitAndCredit),
        (4, ImportErrorCode.missingAmount),
      ]);
    });

    test('accepts comma decimal separators, currency symbols and brackets', () {
      const text =
          'Date;Description;Amount;Reference\n'
          '01/07/2026;Bäckerei;-1.234,50;\n'
          '02/07/2026;Brackets;(\$12,00);\n';
      final result = parseCsvRows(
        text,
        signedMapping(decimalSeparator: ',', delimiter: ';'),
        aud,
      );
      expect(result.errors, isEmpty);
      expect(result.rows.map((r) => r.amount.minor).toList(), [-123450, -1200]);
    });

    test('reports bad dates, bad amounts, zero amounts and short rows', () {
      const text =
          'Date,Description,Amount,Reference\n'
          '31/02/2026,Bad date,-1.00,\n'
          '01/07/2026,Bad amount,abc,\n'
          '01/07/2026,Too precise,1.234,\n'
          '01/07/2026,Zero,0.00,\n'
          '01/07/2026\n'
          '02/07/2026,Good,-5.00,\n';
      final result = parseCsvRows(text, signedMapping(), aud);
      expect(result.rows.single.description, 'Good');
      expect(result.errors.map((e) => (e.row, e.code)).toList(), [
        (2, ImportErrorCode.badDate),
        (3, ImportErrorCode.badAmount),
        (4, ImportErrorCode.badAmount),
        (5, ImportErrorCode.zeroAmount),
        (6, ImportErrorCode.missingField),
      ]);
      expect(ImportErrorCode.badDate.code, 'BAD_DATE');
    });

    test('reports a missing header column and parses nothing', () {
      const text = 'When,Description,Amount\n01/07/2026,x,-1.00\n';
      final result = parseCsvRows(text, signedMapping(), aud);
      expect(result.rows, isEmpty);
      expect(result.errors.single.code, ImportErrorCode.columnNotFound);
      expect(result.errors.single.row, 1);
    });

    test('reference column is optional when the header lacks it', () {
      final mapping = CsvMapping(
        id: 'm3',
        name: 'No refs',
        accountId: 'bank',
        dateColumn: const CsvColumn.header('Date'),
        descriptionColumn: const CsvColumn.header('Description'),
        amountColumn: const CsvColumn.header('Amount'),
      );
      final result = parseCsvRows(
        'Date,Description,Amount\n01/07/2026,x,-1.00\n',
        mapping,
        aud,
      );
      expect(result.rows.single.reference, isNull);
    });

    test('a mapping needs exactly one amount layout', () {
      expect(
        () => CsvMapping(
          id: 'x',
          name: 'x',
          accountId: 'bank',
          dateColumn: const CsvColumn.index(0),
          descriptionColumn: const CsvColumn.index(1),
        ),
        throwsArgumentError,
      );
      expect(
        () => CsvMapping(
          id: 'x',
          name: 'x',
          accountId: 'bank',
          dateColumn: const CsvColumn.index(0),
          descriptionColumn: const CsvColumn.index(1),
          amountColumn: const CsvColumn.index(2),
          debitColumn: const CsvColumn.index(3),
          creditColumn: const CsvColumn.index(4),
        ),
        throwsArgumentError,
      );
    });

    test('decodes bytes with the mapping encoding before parsing', () {
      final bytes = Uint8List.fromList([
        ...latin1.encode('Date,Description,Amount\n01/07/2026,Caf'),
        0xE9,
        ...latin1.encode(',-4.50\n'),
      ]);
      final mapping = CsvMapping(
        id: 'm4',
        name: 'Latin',
        accountId: 'bank',
        encoding: TextEncoding.windows1252,
        dateColumn: const CsvColumn.header('Date'),
        descriptionColumn: const CsvColumn.header('Description'),
        amountColumn: const CsvColumn.header('Amount'),
      );
      final result = parseCsvBytes(bytes, mapping, aud);
      expect(result.rows.single.description, 'Café');
    });
  });

  group('fingerprints', () {
    ImportRow row(
      String date,
      int minor,
      String description, {
      String? reference,
      int rowNumber = 2,
    }) => ImportRow(
      rowNumber: rowNumber,
      date: LocalDate.parse(date),
      amount: Money(minor, aud),
      description: description,
      reference: reference,
      raw: const [],
    );

    test('use the bank reference when present', () {
      expect(
        fingerprintBase(
          'bank',
          row('2026-07-01', -500, 'x', reference: ' R-77 '),
        ),
        'ref|bank|R-77',
      );
    });

    test(
      'otherwise combine account, date, amount and normalised description',
      () {
        expect(
          fingerprintBase(
            'bank',
            row('2026-07-01', -6325, 'WOOLWORTHS  1234, Sydney'),
          ),
          'fp|bank|2026-07-01|-6325|woolworths 1234 sydney',
        );
      },
    );

    test(
      'A11: identical same-day purchases get distinct occurrence counts',
      () {
        final fingerprints = assignFingerprints('bank', [
          row('2026-07-01', -450, 'Coffee Cart'),
          row('2026-07-01', -450, 'COFFEE CART'),
          row('2026-07-01', -900, 'Coffee Cart'),
        ]);
        expect(fingerprints, [
          'fp|bank|2026-07-01|-450|coffee cart#1',
          'fp|bank|2026-07-01|-450|coffee cart#2',
          'fp|bank|2026-07-01|-900|coffee cart#1',
        ]);
      },
    );
  });

  group('CSV writing', () {
    test('sanitises spreadsheet formula prefixes', () {
      for (final value in ['=SUM(A1)', '+61', '-2', '@cmd', '\tx', '\rx']) {
        expect(sanitiseCsvValue(value), "'$value");
      }
      expect(sanitiseCsvValue('Groceries'), 'Groceries');
      expect(sanitiseCsvValue(''), '');
    });

    test('quotes fields that need it', () {
      expect(
        encodeCsv([
          ['a', 'b,c', 'say "hi"', 'two\nlines'],
        ]),
        'a,"b,c","say ""hi""","two\nlines"\r\n',
      );
    });
  });
}
