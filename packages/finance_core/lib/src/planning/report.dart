import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'date_range.dart';

enum ReportValueKind { money, count }

@immutable
class ReportColumn {
  const ReportColumn(this.key, this.label, {this.kind = ReportValueKind.money});

  final String key;
  final String label;
  final ReportValueKind kind;
}

/// One report row with the source journals behind it for drill-through.
@immutable
class ReportRow {
  ReportRow({
    required this.key,
    required this.label,
    Map<String, Money> amounts = const {},
    Map<String, int> counts = const {},
    List<String> journalIds = const [],
  }) : amounts = Map.unmodifiable(amounts),
       counts = Map.unmodifiable(counts),
       journalIds = List.unmodifiable(journalIds);

  final String key;
  final String label;
  final Map<String, Money> amounts;
  final Map<String, int> counts;
  final List<String> journalIds;

  Money amount(String column) =>
      amounts[column] ?? (throw ArgumentError.value(column, 'column'));

  int count(String column) =>
      counts[column] ?? (throw ArgumentError.value(column, 'column'));
}

/// Tabular report data (REP 01). Charts and the accessible table beside
/// them render from the same rows.
@immutable
class Report {
  Report({
    required this.title,
    required this.keyLabel,
    required List<ReportColumn> columns,
    required List<ReportRow> rows,
    this.range,
    this.asOf,
    this.includesUnsyncedChanges = false,
  }) : columns = List.unmodifiable(columns),
       rows = List.unmodifiable(rows);

  final String title;

  /// Heading of the row label column, for example `Category`.
  final String keyLabel;
  final List<ReportColumn> columns;
  final List<ReportRow> rows;
  final DateRange? range;
  final LocalDate? asOf;

  /// Whether the figures include local changes not yet synchronised
  /// (REP 04).
  final bool includesUnsyncedChanges;

  ReportRow? row(String key) {
    for (final row in rows) {
      if (row.key == key) return row;
    }
    return null;
  }

  /// Header row followed by one row per entry, as display strings.
  List<List<String>> toTable() => [
    [keyLabel, for (final c in columns) c.label],
    for (final row in rows)
      [
        row.label,
        for (final c in columns)
          c.kind == ReportValueKind.money
              ? row.amount(c.key).toDecimalString()
              : row.count(c.key).toString(),
      ],
  ];
}
