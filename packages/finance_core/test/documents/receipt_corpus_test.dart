import 'dart:convert';
import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

/// Runs the parser over the synthetic receipt corpus and reports exact
/// field accuracy per class (test strategy, PRD section 16). A value with
/// no expectation (`null`, not legible) counts as correct only when the
/// parser offers no candidate.
void main() {
  final dir = _corpusDir();
  final manifest = jsonDecode(
    File('${dir.path}/manifest.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final receipts = (manifest['receipts'] as List).cast<Map<String, dynamic>>();

  final conventions = <String, DateConvention>{
    for (final r in receipts)
      if (r['merchantDateConvention'] != null)
        normaliseMerchant(r['merchant'] as String): DateConvention.values
            .byName(r['merchantDateConvention'] as String),
  };
  final settings = ParserSettings(
    merchantDateConventions: conventions,
    referenceDate: LocalDate(2026, 11, 30),
  );

  test('the corpus has at least 30 receipts across every class', () {
    expect(receipts.length, greaterThanOrEqualTo(30));
    expect(receipts.map((r) => r['class']).toSet(), {
      'supermarket',
      'cafe',
      'fuel',
      'parking',
      'online',
      'refund',
      'faded',
      'long',
      'cash',
    });
  });

  test('reports exact-match accuracy for total and date', () {
    final tally = <String, List<int>>{}; // class -> [n, total, date, merchant]
    final misses = <String>[];
    for (final receipt in receipts) {
      final file = receipt['file'] as String;
      final text = File('${dir.path}/$file').readAsStringSync();
      final extraction = parseReceipt(
        OcrResult.fromText(text, engine: 'corpus', engineVersion: '1'),
        id: file,
        receiptId: file,
        createdAt: DateTime.utc(2026, 11, 30),
        settings: settings,
      );
      final total = extraction.total.firstOrNull?.value.toDecimalString();
      final date = extraction.date.firstOrNull?.value.toString();
      final merchant = extraction.merchant.firstOrNull?.value;
      final cls = receipt['class'] as String;
      final counts = tally.putIfAbsent(cls, () => [0, 0, 0, 0]);
      counts[0]++;
      if (total == receipt['total']) {
        counts[1]++;
      } else {
        misses.add('$file total $total != ${receipt['total']}');
      }
      if (date == receipt['date']) {
        counts[2]++;
      } else {
        misses.add('$file date $date != ${receipt['date']}');
      }
      if (merchant == receipt['merchant']) {
        counts[3]++;
      } else {
        misses.add('$file merchant $merchant != ${receipt['merchant']}');
      }
      if (receipt['refund'] == true) {
        expect(extraction.isRefund, isTrue, reason: file);
        expect(
          extraction.reviewReasons,
          contains(UncertaintyReason.refundReceipt),
        );
      }
    }
    var n = 0, totals = 0, dates = 0, merchants = 0;
    final report = StringBuffer('Receipt corpus exact-match accuracy\n');
    for (final entry in tally.entries) {
      final c = entry.value;
      n += c[0];
      totals += c[1];
      dates += c[2];
      merchants += c[3];
      report.writeln(
        '  ${entry.key.padRight(12)} n=${c[0]}  total ${c[1]}/${c[0]}  '
        'date ${c[2]}/${c[0]}  merchant ${c[3]}/${c[0]}',
      );
    }
    report.writeln(
      '  overall      n=$n  total $totals/$n  date $dates/$n  '
      'merchant $merchants/$n',
    );
    for (final miss in misses) {
      report.writeln('  miss: $miss');
    }
    print(report);
    expect(totals / n, greaterThanOrEqualTo(0.9), reason: '$report');
    expect(dates / n, greaterThanOrEqualTo(0.9), reason: '$report');
  });
}

Directory _corpusDir() {
  for (final path in [
    'test/documents/corpus',
    'packages/finance_core/test/documents/corpus',
  ]) {
    final dir = Directory(path);
    if (File('${dir.path}/manifest.json').existsSync()) return dir;
  }
  throw StateError('Receipt corpus not found from ${Directory.current.path}');
}
