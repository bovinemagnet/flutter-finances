import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/ledger_helpers.dart';

const sgmlStatement = '''
OFXHEADER:100
DATA:OFXSGML
VERSION:102
SECURITY:NONE
ENCODING:USASCII
CHARSET:1252
COMPRESSION:NONE
OLDFILEUID:NONE
NEWFILEUID:NONE

<OFX>
<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>
<DTSERVER>20261020120000<LANGUAGE>ENG</SONRS></SIGNONMSGSRSV1>
<BANKMSGSRSV1><STMTTRNRS><TRNUID>1<STATUS><CODE>0<SEVERITY>INFO</STATUS>
<STMTRS><CURDEF>AUD
<BANKACCTFROM><BANKID>062000<ACCTID>12345678<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><DTSTART>20261001<DTEND>20261019
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20261003120000[+10:AEST]
<TRNAMT>-45.20
<FITID>2026100301
<NAME>WOOLWORTHS 1234
<MEMO>Card purchase
</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261015<TRNAMT>2500.00<FITID>2026101502<NAME>ACME PAYROLL &amp; CO</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20261018
<TRNAMT>-12.50
<FITID>2026101803
<NAME>CAFE
<MEMO>CAFE
</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>1234.56<DTASOF>20261019</LEDGERBAL>
</STMTRS></STMTTRNRS></BANKMSGSRSV1>
</OFX>
''';

const xmlCardStatement =
    '''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?OFX OFXHEADER="200" VERSION="220" SECURITY="NONE" OLDFILEUID="NONE" NEWFILEUID="NONE"?>
<OFX>
  <CREDITCARDMSGSRSV1>
    <CCSTMTTRNRS>
      <TRNUID>1</TRNUID>
      <CCSTMTRS>
        <CURDEF>AUD</CURDEF>
        <CCACCTFROM><ACCTID>4111XXXXXXXX1111</ACCTID></CCACCTFROM>
        <BANKTRANLIST>
          <DTSTART>20261001</DTSTART>
          <DTEND>20261031</DTEND>
          <STMTTRN>
            <TRNTYPE>DEBIT</TRNTYPE>
            <DTPOSTED>20261005</DTPOSTED>
            <TRNAMT>-89.95</TRNAMT>
            <FITID>CC-1</FITID>
            <NAME>JB HI-FI</NAME>
            <MEMO></MEMO>
          </STMTTRN>
          <STMTTRN>
            <TRNTYPE>CREDIT</TRNTYPE>
            <DTPOSTED>20261020</DTPOSTED>
            <TRNAMT>500.00</TRNAMT>
            <FITID>CC-2</FITID>
            <NAME>PAYMENT THANK YOU</NAME>
          </STMTTRN>
        </BANKTRANLIST>
        <LEDGERBAL><BALAMT>-1520.40</BALAMT><DTASOF>20261031</DTASOF></LEDGERBAL>
      </CCSTMTRS>
    </CCSTMTTRNRS>
  </CREDITCARDMSGSRSV1>
</OFX>
''';

const qifStatement = '''!Type:Bank
D03/10/2026
T-45.20
PWOOLWORTHS 1234
MCard purchase
N1001
LGroceries
^
D15/10'26
U2,500.00
T2,500.00
PACME PAYROLL
^
D18/10/2026
T-12.50
PCAFE
^
D18/10/2026
T-12.50
PCAFE
^
''';

void main() {
  group('OFX', () {
    test('reads an OFX 1.x SGML bank statement', () {
      final result = parseOfx(sgmlStatement, aud);
      expect(result.errors, isEmpty);
      expect(result.accountId, '12345678');
      expect(result.bankId, '062000');
      expect(result.accountType, 'CHECKING');
      expect(result.isCreditCard, isFalse);
      expect(result.currencyCode, 'AUD');
      expect(result.ledgerBalance, m('1234.56'));
      expect(result.ledgerBalanceDate, d('2026-10-19'));
      expect(result.statementStart, d('2026-10-01'));
      expect(result.statementEnd, d('2026-10-19'));
      expect(result.rows, hasLength(3));
      final first = result.rows.first;
      expect(first.rowNumber, 1);
      expect(first.date, d('2026-10-03'));
      expect(first.amount, m('-45.20'));
      expect(first.description, 'WOOLWORTHS 1234 - Card purchase');
      expect(first.reference, '2026100301');
      expect(first.raw, contains('TRNTYPE=DEBIT'));
      expect(result.rows[1].description, 'ACME PAYROLL & CO');
      expect(result.rows[1].amount, m('2500.00'));
      // A memo repeating the name is not appended.
      expect(result.rows[2].description, 'CAFE');
    });

    test('reads an OFX 2.x XML credit card statement', () {
      final result = parseOfx(xmlCardStatement, aud);
      expect(result.errors, isEmpty);
      expect(result.isCreditCard, isTrue);
      expect(result.accountId, '4111XXXXXXXX1111');
      expect(result.ledgerBalance, m('-1520.40'));
      expect(
        [for (final r in result.rows) r.amount],
        [m('-89.95'), m('500.00')],
      );
      expect(result.rows.first.description, 'JB HI-FI');
      expect(result.rows.first.reference, 'CC-1');
    });

    test('reports row errors and a file that is not OFX', () {
      const text = '''<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS>
<BANKACCTFROM><ACCTID>1</BANKACCTFROM><BANKTRANLIST>
<STMTTRN><DTPOSTED>2026-10-03<TRNAMT>-1.00<FITID>a</STMTTRN>
<STMTTRN><DTPOSTED>20261003<TRNAMT>abc<FITID>b</STMTTRN>
<STMTTRN><TRNAMT>-1.00<FITID>c</STMTTRN>
<STMTTRN><DTPOSTED>20261003<FITID>d</STMTTRN>
<STMTTRN><DTPOSTED>20261003<TRNAMT>0.00<FITID>e</STMTTRN>
<STMTTRN><DTPOSTED>20261003<TRNAMT>-1.5000<FITID>f</STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>''';
      final result = parseOfx(text, aud);
      expect(
        [for (final e in result.errors) (e.row, e.code)],
        [
          (1, ImportErrorCode.badDate),
          (2, ImportErrorCode.badAmount),
          (3, ImportErrorCode.missingField),
          (4, ImportErrorCode.missingAmount),
          (5, ImportErrorCode.zeroAmount),
        ],
      );
      expect(result.rows.single.amount, m('-1.50'));
      expect(result.rows.single.rowNumber, 6);

      final notOfx = parseOfx('Date,Amount\n1/1/2026,1.00', aud);
      expect(notOfx.rows, isEmpty);
      expect(notOfx.errors.single.code, ImportErrorCode.unrecognisedFormat);
      expect(notOfx.errors.single.row, 0);
    });

    test('chooses the statement for an account when a file has several', () {
      final text = sgmlStatement.replaceFirst(
        '</BANKMSGSRSV1>',
        '<STMTTRNRS><STMTRS><BANKACCTFROM><ACCTID>999</BANKACCTFROM>'
            '<BANKTRANLIST><STMTTRN><DTPOSTED>20261001<TRNAMT>-3.00'
            '<FITID>z</STMTTRN></BANKTRANLIST></STMTRS></STMTTRNRS>'
            '</BANKMSGSRSV1>',
      );
      final first = parseOfx(text, aud);
      expect(first.accountId, '12345678');
      expect(first.otherAccountIds, ['999']);
      final second = parseOfx(text, aud, accountId: '999');
      expect(second.rows.single.amount, m('-3.00'));
      expect(second.otherAccountIds, ['12345678']);
    });

    test('decodes bytes using the declared Windows-1252 character set', () {
      final text = sgmlStatement.replaceFirst('CAFE\n<MEMO>CAFE', 'CAFÉ');
      final bytes = Uint8List.fromList(latin1.encode(text));
      expect(parseOfxBytes(bytes, aud).rows[2].description, 'CAFÉ');
    });

    test('flows through preview and commit with FITID fingerprints', () {
      final bytes = Uint8List.fromList(utf8.encode(sgmlStatement));
      ImportPreview preview({List<SourceRecord> records = const []}) =>
          previewImport(
            accountId: 'bank',
            parsed: parseOfxBytes(bytes, aud),
            sourceHash: sourceHashOf(bytes),
            chart: testChart,
            existingRecords: records,
          );
      final first = preview();
      expect(first.rows.map((r) => r.fingerprint), [
        'ref|bank|2026100301#1',
        'ref|bank|2026101502#1',
        'ref|bank|2026101803#1',
      ]);
      final committed = commitImport(
        preview: first,
        chart: testChart,
        batchId: 'b1',
        importedAt: DateTime.utc(2026, 10, 20),
        uncategorisedExpenseId: 'uncategorised',
        uncategorisedIncomeId: 'other-income',
      );
      expect(committed.drafts, hasLength(3));
      expect(committed.sourceRecords.first.reference, '2026100301');
      // Importing an overlapping export again finds every row by FITID.
      final again = preview(records: committed.sourceRecords);
      expect(
        again.rows.map((r) => r.status),
        everyElement(PreviewRowStatus.duplicate),
      );
    });
  });

  group('QIF', () {
    test('reads a bank QIF file', () {
      final result = parseQif(qifStatement, aud);
      expect(result.errors, isEmpty);
      expect(result.accountType, 'Bank');
      expect(result.rows, hasLength(4));
      final first = result.rows.first;
      expect(first.rowNumber, 1);
      expect(first.date, d('2026-10-03'));
      expect(first.amount, m('-45.20'));
      expect(first.description, 'WOOLWORTHS 1234 - Card purchase');
      expect(first.reference, isNull);
      expect(first.raw, [
        'D03/10/2026',
        'T-45.20',
        'PWOOLWORTHS 1234',
        'MCard purchase',
        'N1001',
        'LGroceries',
      ]);
      expect(result.rows[1].date, d('2026-10-15'));
      expect(result.rows[1].amount, m('2500.00'));
    });

    test('identical QIF rows keep separate fingerprints (A11)', () {
      final result = parseQif(qifStatement, aud);
      final prints = assignFingerprints('bank', result.rows);
      expect(prints[2], 'fp|bank|2026-10-18|-1250|cafe#1');
      expect(prints[3], 'fp|bank|2026-10-18|-1250|cafe#2');
    });

    test('reads credit card files and skips other sections', () {
      const text = '''!Option:AutoSwitch
!Account
NVisa
TCCard
^
!Clear:AutoSwitch
!Type:Cat
NGroceries
E
^
!Type:CCard
D10/5/2026
T-20.00
PSHELL
^
D10/6/2026
T(5.00)
PREFUND
^''';
      final us = parseQif(text, aud, dateConvention: DateConvention.monthDay);
      expect(us.accountType, 'CCard');
      expect(
        [for (final r in us.rows) r.date],
        [d('2026-10-05'), d('2026-10-06')],
      );
      expect(us.rows[1].amount, m('-5.00'));
    });

    test('reports row errors and a file that is not QIF', () {
      const text = '''!Type:Bank
T-1.00
PNO DATE
^
D31/02/2026
T-1.00
^
D01/02/2026
Tabc
^
D01/02/2026
PNO AMOUNT
^
D01/02/2026
T0.00
^
D01/02/2026
T-2.00
''';
      final result = parseQif(text, aud);
      expect(
        [for (final e in result.errors) (e.row, e.code)],
        [
          (1, ImportErrorCode.missingField),
          (2, ImportErrorCode.badDate),
          (3, ImportErrorCode.badAmount),
          (4, ImportErrorCode.missingAmount),
          (5, ImportErrorCode.zeroAmount),
        ],
      );
      expect(result.rows.single.rowNumber, 6);
      expect(result.rows.single.amount, m('-2.00'));

      final notQif = parseQif('Date,Amount', aud);
      expect(notQif.errors.single.code, ImportErrorCode.unrecognisedFormat);
    });

    test('parses QIF date forms', () {
      LocalDate? dm(String t) => parseQifDate(t, DateConvention.dayMonth);
      LocalDate? md(String t) => parseQifDate(t, DateConvention.monthDay);
      expect(dm('19/10/2026'), d('2026-10-19'));
      expect(md('10/19/2026'), d('2026-10-19'));
      expect(md("10/19'26"), d('2026-10-19'));
      expect(md(" 1/ 9' 5"), d('2005-01-09'));
      expect(md('12/31/99'), d('1999-12-31'));
      expect(md('1/1/05'), d('2005-01-01'));
      expect(dm('19.10.2026'), d('2026-10-19'));
      expect(dm('19-10-2026'), d('2026-10-19'));
      expect(md('2026-10-19'), d('2026-10-19'));
      expect(dm('10/19/2026'), isNull);
      expect(dm('31/02/2026'), isNull);
      expect(dm('yesterday'), isNull);
    });

    test('suggests the date convention from unambiguous dates', () {
      expect(detectQifDateConvention(qifStatement), DateConvention.dayMonth);
      expect(
        detectQifDateConvention('!Type:Bank\nD10/19/2026\nT1.00\n^'),
        DateConvention.monthDay,
      );
      expect(detectQifDateConvention('!Type:Bank\nD10/09/2026\n^'), isNull);
    });
  });
}
