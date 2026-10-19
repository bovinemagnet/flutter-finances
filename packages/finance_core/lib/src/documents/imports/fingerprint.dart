import '../text/normalise.dart';
import 'csv_parse.dart';

/// The fingerprint of a row before its occurrence count (IMP 02).
///
/// - With a bank or provider reference: `ref|<accountId>|<reference>`, the
///   reference trimmed.
/// - Otherwise a candidate fingerprint:
///   `fp|<accountId>|<YYYY-MM-DD>|<amountMinor>|<normalised description>`,
///   using [normaliseText] for the description.
String fingerprintBase(String accountId, ImportRow row) {
  final reference = row.reference?.trim() ?? '';
  if (reference.isNotEmpty) return 'ref|$accountId|$reference';
  return 'fp|$accountId|${row.date}|${row.amount.minor}|'
      '${normaliseText(row.description)}';
}

/// Fingerprints for rows in file order: the base followed by `#` and the
/// 1-based occurrence of that base so far in the file.
///
/// Two legitimate identical purchases on the same day become `...#1` and
/// `...#2`, so both survive a re-import check instead of one being taken
/// for a duplicate of the other (A11).
List<String> assignFingerprints(String accountId, Iterable<ImportRow> rows) {
  final seen = <String, int>{};
  return [
    for (final row in rows)
      () {
        final base = fingerprintBase(accountId, row);
        final occurrence = (seen[base] ?? 0) + 1;
        seen[base] = occurrence;
        return '$base#$occurrence';
      }(),
  ];
}

/// Splits a fingerprint into its base and occurrence count.
(String base, int occurrence) splitFingerprint(String fingerprint) {
  final at = fingerprint.lastIndexOf('#');
  return (
    fingerprint.substring(0, at),
    int.parse(fingerprint.substring(at + 1)),
  );
}
