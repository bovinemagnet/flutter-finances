import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_app/data/app_state.dart';
import 'package:finance_app/data/import_service.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _fastKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);

void main() {
  late Directory dir;
  late AppState state;
  late ImportService imports;

  final csv = Uint8List.fromList(
    utf8.encode('''Date,Description,Amount
01/10/2026,COFFEE CART,-4.50
01/10/2026,COFFEE CART,-4.50
02/10/2026,SALARY ACME,3123.45
'''),
  );

  CsvMapping mapping() => CsvMapping(
    id: 'm1',
    name: 'Everyday bank',
    accountId: 'bank',
    dateColumn: const CsvColumn.header('Date'),
    descriptionColumn: const CsvColumn.header('Description'),
    amountColumn: const CsvColumn.header('Amount'),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('import_test');
    final store = await FinanceStore.create(
      dir,
      keyProtection: KeyProtection.password('secret', kdf: _fastKdf),
    );
    await store.createAccount(
      const Account(
        id: 'bank',
        name: 'Everyday',
        type: AccountType.transaction,
      ),
    );
    state = AppState(store, today: () => LocalDate(2026, 10, 19));
    imports = ImportService(state);
  });

  tearDown(() async {
    await state.store.close();
    await dir.delete(recursive: true);
  });

  test('keeps two legitimate identical purchases (A11)', () async {
    final preview = imports.preview(csv, mapping());
    expect(preview.errors, isEmpty);
    expect(
      preview.rows.where((r) => r.status == PreviewRowStatus.newEntry),
      hasLength(3),
    );
    final result = await imports.commit(
      preview,
      mapping(),
      fileName: 'oct.csv',
    );
    expect(result.posted, 3);
    expect(state.ledger.displayBalance('bank'), Money(311445, Currency.aud));
    expect(imports.batches, hasLength(1));
    expect(imports.sourceRecords, hasLength(3));
  });

  test('re-importing the same batch adds nothing (A12)', () async {
    await imports.commit(imports.preview(csv, mapping()), mapping());
    final again = imports.preview(csv, mapping());
    expect(again.alreadyImportedBatch, isNotNull);
    final result = await imports.commit(again, mapping());
    expect(result.posted, 0);
    expect(result.alreadyCommitted, isTrue);
    expect(state.ledger.journals, hasLength(3));
  });

  test('saved mappings are reusable', () async {
    await imports.saveMapping(mapping());
    expect(imports.mappings.single.name, 'Everyday bank');
  });

  test('OFX and QIF statements import without a column mapping', () async {
    final ofx = Uint8List.fromList(utf8.encode('''OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>AUD
<BANKACCTFROM><BANKID>062000<ACCTID>12345678<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><DTSTART>20261001<DTEND>20261031
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261003<TRNAMT>-4.50<FITID>A1<NAME>COFFEE CART</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261005<TRNAMT>3123.45<FITID>A2<NAME>SALARY ACME</STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
'''));
    expect(detectStatementFormat(ofx, 'oct.ofx'), StatementFormat.ofx);
    final preview = imports.previewStatement(ofx, StatementFormat.ofx, accountId: 'bank');
    expect(preview.rows, hasLength(2));
    final outcome = await imports.commitStatement(preview, accountId: 'bank', fileName: 'oct.ofx');
    expect(outcome.posted, 2);
    final again = imports.previewStatement(ofx, StatementFormat.ofx, accountId: 'bank');
    expect(again.alreadyImportedBatch, isNotNull);

    final qif = Uint8List.fromList(utf8.encode('!Type:Bank\nD03/10/2026\nT-12.00\nPCORNER STORE\n^\n'));
    expect(detectStatementFormat(qif, 'x.qif'), StatementFormat.qif);
    expect(imports.previewStatement(qif, StatementFormat.qif, accountId: 'bank').rows,
        hasLength(1));
    expect(detectStatementFormat(csv, 'oct.csv'), StatementFormat.csv);
  });
}
