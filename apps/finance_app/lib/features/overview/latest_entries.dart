import 'package:finance_core/finance_core.dart';

/// The newest [count] entries, leaving out reversals, newest first.
///
/// Entries tied on date and time keep the order they came in. A workspace can
/// hold hundreds of thousands of entries, so this keeps only the best so far
/// and does not sort them all on every build (NFR 02).
List<Journal> latestEntries(Iterable<Journal> journals, int count) {
  final latest = <Journal>[];
  if (count <= 0) return latest;
  for (final journal in journals) {
    if (journal.type == TransactionType.reversal) continue;
    if (latest.length == count && !_isNewer(journal, latest.last)) continue;
    var at = latest.length;
    while (at > 0 && _isNewer(journal, latest[at - 1])) {
      at--;
    }
    if (latest.length == count) latest.removeLast();
    latest.insert(at, journal);
  }
  return latest;
}

bool _isNewer(Journal a, Journal b) {
  final byDate = a.effectiveDate.compareTo(b.effectiveDate);
  return byDate != 0 ? byDate > 0 : a.enteredAt.isAfter(b.enteredAt);
}
