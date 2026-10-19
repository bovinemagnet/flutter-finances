/// Characters that make spreadsheet applications treat a cell as a formula
/// (or, for tab and carriage return, can smuggle one past a check).
const formulaPrefixes = {'=', '+', '-', '@', '\t', '\r'};

/// Neutralises spreadsheet formula injection in a user text value (EXP 01)
/// by prefixing an apostrophe when the value starts with `=`, `+`, `-`,
/// `@`, a tab or a carriage return. Apply it to text fields only; numeric
/// amounts are written unsanitised so they stay numbers.
String sanitiseCsvValue(String value) =>
    value.isNotEmpty && formulaPrefixes.contains(value[0]) ? "'$value" : value;

/// Quotes a field when it contains the delimiter, a quote or a line break,
/// doubling embedded quotes (RFC 4180).
String encodeCsvField(String value, {String delimiter = ','}) {
  final needsQuotes =
      value.contains(delimiter) ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r');
  return needsQuotes ? '"${value.replaceAll('"', '""')}"' : value;
}

/// Encodes rows as CSV with CRLF line endings, each row ending in CRLF.
String encodeCsv(
  Iterable<List<String>> rows, {
  String delimiter = ',',
  String lineEnding = '\r\n',
}) {
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer
      ..write(
        row.map((v) => encodeCsvField(v, delimiter: delimiter)).join(delimiter),
      )
      ..write(lineEnding);
  }
  return buffer.toString();
}
