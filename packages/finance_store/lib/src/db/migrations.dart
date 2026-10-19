import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// One forward-only schema step (NFR 11).
@immutable
class Migration {
  const Migration(this.version, this.description, this.apply);

  final int version;
  final String description;
  final void Function(Database db) apply;
}

class SchemaTooNewException implements Exception {
  SchemaTooNewException(this.found, this.supported);
  final int found;
  final int supported;

  @override
  String toString() =>
      'Database schema $found is newer than supported $supported; '
      'update the application';
}

class MigrationFailedException implements Exception {
  MigrationFailedException(this.version, this.cause);
  final int version;
  final Object cause;

  @override
  String toString() => 'Migration to version $version failed: $cause';
}

int userVersion(Database db) =>
    db.select('PRAGMA user_version').first.values.first as int;

/// Applies every migration above the database's `user_version`.
///
/// Each step runs in its own immediate transaction together with the
/// `user_version` update, so a crash or error leaves the database at the
/// previous complete version and the step is simply retried on next open.
/// [beforeUpgrade] is called once with the current version before an
/// existing database is upgraded, so the caller can keep a recovery copy.
void migrate(
  Database db,
  List<Migration> migrations, {
  void Function(int fromVersion)? beforeUpgrade,
}) {
  final latest = migrations.isEmpty ? 0 : migrations.last.version;
  final current = userVersion(db);
  if (current > latest) throw SchemaTooNewException(current, latest);
  final pending = migrations.where((m) => m.version > current).toList();
  if (pending.isEmpty) return;
  if (current > 0) beforeUpgrade?.call(current);
  for (final migration in pending) {
    db.execute('BEGIN IMMEDIATE');
    try {
      migration.apply(db);
      db.execute('PRAGMA user_version = ${migration.version}');
      db.execute('COMMIT');
    } catch (e) {
      if (!db.autocommit) db.execute('ROLLBACK');
      throw MigrationFailedException(migration.version, e);
    }
  }
}
