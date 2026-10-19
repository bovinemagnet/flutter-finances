import 'package:sqlite3/sqlite3.dart';

class WrongDatabaseKeyException implements Exception {
  @override
  String toString() => 'The database key is wrong or the file is damaged';
}

/// Thrown when the linked SQLite has no cipher support, which would
/// otherwise silently create a plaintext database.
class EncryptionUnavailableException implements Exception {
  @override
  String toString() =>
      'SQLite3MultipleCiphers is not linked; set the sqlite3 hook source '
      'to sqlite3mc in the workspace pubspec';
}

/// Opens (or creates) a SQLite3MultipleCiphers database with a raw 256-bit
/// key given as 64 hex digits.
///
/// The key is applied before any other statement. The default cipher is
/// ChaCha20-Poly1305 (sqleet compatible), which authenticates every page.
/// Write-ahead logging with `synchronous = FULL` makes each commit durable
/// before it returns (NFR 01, REC 03).
Database openEncryptedDatabase(String path, String hexKey) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hexKey)) {
    throw ArgumentError('Expected a 256-bit hex key');
  }
  final db = sqlite3.open(path);
  try {
    db.execute("PRAGMA hexkey = '$hexKey'");
    final cipher = db.select('PRAGMA cipher');
    if (cipher.isEmpty || '${cipher.first.values.first}'.isEmpty) {
      throw EncryptionUnavailableException();
    }
    try {
      db.select('SELECT count(*) FROM sqlite_master');
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 26 || e.resultCode == 26) {
        throw WrongDatabaseKeyException();
      }
      rethrow;
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

/// Runs [action] inside an immediate transaction, rolling back on error.
T transaction<T>(Database db, T Function() action) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final result = action();
    db.execute('COMMIT');
    return result;
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}
