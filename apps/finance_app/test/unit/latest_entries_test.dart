import 'dart:math';

import 'package:finance_app/features/overview/latest_entries.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter_test/flutter_test.dart';

Journal _journal(
  String id,
  LocalDate date,
  DateTime enteredAt, {
  TransactionType type = TransactionType.expense,
}) => Journal(
  id: id,
  type: type,
  status: JournalStatus.posted,
  effectiveDate: date,
  enteredAt: enteredAt,
  postings: const [],
);

void main() {
  /// The definition: everything but reversals, newest first, then the top.
  List<Journal> bySorting(List<Journal> journals, int count) {
    final sorted =
        journals.where((j) => j.type != TransactionType.reversal).toList()
          ..sort((a, b) {
            final byDate = b.effectiveDate.compareTo(a.effectiveDate);
            return byDate != 0 ? byDate : b.enteredAt.compareTo(a.enteredAt);
          });
    return sorted.take(count).toList();
  }

  test('matches sorting everything, whatever the mix', () {
    final random = Random(3);
    for (var round = 0; round < 500; round++) {
      final size = random.nextInt(30);
      final journals = [
        for (var i = 0; i < size; i++)
          _journal(
            'j$i',
            // Few dates and times, so ties are common.
            LocalDate(2026, 10, 1 + random.nextInt(4)),
            DateTime.utc(2026, 10, 1, random.nextInt(3)),
            type: random.nextInt(5) == 0
                ? TransactionType.reversal
                : TransactionType.expense,
          ),
      ];
      final count = random.nextInt(8);
      String key(Journal j) => '${j.effectiveDate} ${j.enteredAt}';
      final latest = latestEntries(journals, count);
      expect(
        latest.map(key).toList(),
        bySorting(journals, count).map(key).toList(),
      );
      expect(latest.map((j) => j.id).toSet(), hasLength(latest.length));
      expect(journals, containsAll(latest));
    }
  });

  test('entries tied on date and time keep the order they came in', () {
    final date = LocalDate(2026, 10, 1);
    final at = DateTime.utc(2026, 10, 1);
    final journals = [for (var i = 0; i < 5; i++) _journal('j$i', date, at)];
    expect(latestEntries(journals, 3).map((j) => j.id), ['j0', 'j1', 'j2']);
  });

  test('leaves what it is given alone', () {
    final journals = List<Journal>.unmodifiable([
      _journal('a', LocalDate(2026, 10, 1), DateTime.utc(2026)),
      _journal('b', LocalDate(2026, 10, 2), DateTime.utc(2026)),
    ]);
    expect(latestEntries(journals, 6).map((j) => j.id), ['b', 'a']);
  });
}
