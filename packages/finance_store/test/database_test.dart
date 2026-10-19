import 'dart:convert';
import 'dart:io';

import 'package:finance_store/finance_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  final key = DataKey.generate();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('finance_db');
    path = '${dir.path}/finance.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('encryption', () {
    test('the file is not readable SQLite and reports a cipher', () {
      final db = openEncryptedDatabase(path, key.databaseKeyHex);
      expect(db.select('PRAGMA cipher').first.values.first, isNotEmpty);
      db.execute("CREATE TABLE secret(x); INSERT INTO secret VALUES ('payee')");
      db.close();
      final bytes = File(path).readAsBytesSync();
      expect(
        ascii.decode(bytes.sublist(0, 15), allowInvalid: true),
        isNot('SQLite format 3'),
      );
      expect(latin1.decode(bytes).contains('payee'), isFalse);
    });

    test('a wrong key cannot open the database', () {
      openEncryptedDatabase(path, key.databaseKeyHex)
        ..execute('CREATE TABLE t(x)')
        ..close();
      expect(
        () => openEncryptedDatabase(path, DataKey.generate().databaseKeyHex),
        throwsA(isA<WrongDatabaseKeyException>()),
      );
      final plain = sqlite3.open(path);
      expect(() => plain.select('SELECT * FROM t'), throwsA(anything));
      plain.close();
    });

    test('durability settings are applied', () {
      final db = openEncryptedDatabase(path, key.databaseKeyHex);
      expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
      expect(db.select('PRAGMA synchronous').first.values.first, 2);
      expect(db.select('PRAGMA foreign_keys').first.values.first, 1);
      db.close();
    });
  });

  group('migrations', () {
    test('a new database is created at the latest version', () {
      final db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations);
      expect(userVersion(db), latestSchemaVersion);
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'workspace',
          'accounts',
          'categories',
          'journals',
          'postings',
          'entities',
          'outbox',
          'outbox_keys',
          'sync_state',
          'conflicts',
          'assets',
          'search_index',
        ]),
      );
      db.close();
    });

    test('upgrades a version 1 database to the latest, keeping data', () {
      var db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations.take(1).toList());
      expect(userVersion(db), 1);
      db.execute('''
        INSERT INTO journals (id, type, status, effective_date, entered_at,
          currency, account_id, amount_minor, payee, notes, tags_json,
          updated_at)
        VALUES ('j1', 'expense', 'posted', '2026-07-01',
          '2026-07-01T00:00:00.000Z', 'AUD', 'bank', 1000, 'Corner Grocer',
          'weekly shop', '["food"]', '2026-07-01T00:00:00.000Z');
        INSERT INTO postings VALUES ('j1', 0, 'groceries', 1000, 'posted',
          '2026-07-01');
        INSERT INTO postings VALUES ('j1', 1, 'bank', -1000, 'posted',
          '2026-07-01');
        INSERT INTO entities (entity_type, id, json, updated_at)
        VALUES ('receipt', 'r1', '{"merchant":"Corner Grocer","text":"milk"}',
          '2026-07-01T00:00:00.000Z');
      ''');
      db.close();

      db = openEncryptedDatabase(path, key.databaseKeyHex);
      final backups = <int>[];
      migrate(db, financeMigrations, beforeUpgrade: backups.add);
      expect(backups, [1]);
      expect(userVersion(db), latestSchemaVersion);
      expect(
        db.select("SELECT SUM(amount_minor) s FROM postings").first['s'],
        0,
      );
      final hits = db.select(
        'SELECT d.entity_type, d.entity_id FROM search_index s '
        'JOIN search_docs d ON d.doc_id = s.rowid '
        "WHERE search_index MATCH 'grocer'",
      );
      expect(hits.map((r) => '${r['entity_type']}:${r['entity_id']}').toSet(), {
        'journal:j1',
        'receipt:r1',
      });
      expect(db.select('SELECT * FROM assets'), isEmpty);
      db.close();
    });

    test('version 4 adds account sharing with private as the default', () {
      var db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations.take(3).toList());
      db.execute('''
        INSERT INTO accounts (id, name, type, include_in_budget,
          include_in_forecast, include_in_net_worth, archived, data_source,
          updated_at)
        VALUES ('bank', 'Everyday', 'transaction', 1, 1, 1, 0, 'manual',
          '2026-07-01T00:00:00.000Z');
      ''');
      db.close();
      db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations);
      expect(
        db
            .select("SELECT sharing FROM accounts WHERE id = 'bank'")
            .first['sharing'],
        'private',
      );
      db.close();
    });

    test('a failing migration rolls back and can be retried', () {
      var db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations.take(1).toList());
      db.execute(
        "INSERT INTO sync_state (key, value) VALUES ('cursor', 'c-1')",
      );
      db.close();

      final broken = [
        financeMigrations.first,
        Migration(2, 'crashes half way', (db) {
          db.execute('CREATE TABLE half_done(x)');
          throw StateError('simulated crash');
        }),
      ];
      db = openEncryptedDatabase(path, key.databaseKeyHex);
      expect(
        () => migrate(db, broken),
        throwsA(isA<MigrationFailedException>()),
      );
      expect(userVersion(db), 1);
      expect(
        db.select("SELECT name FROM sqlite_master WHERE name = 'half_done'"),
        isEmpty,
      );
      db.close();

      db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations);
      expect(userVersion(db), latestSchemaVersion);
      expect(
        db
            .select("SELECT value FROM sync_state WHERE key = 'cursor'")
            .first
            .columnAt(0),
        'c-1',
      );
      db.close();
    });

    test('refuses a database from a newer application version', () {
      final db = openEncryptedDatabase(path, key.databaseKeyHex);
      migrate(db, financeMigrations);
      db.execute('PRAGMA user_version = ${latestSchemaVersion + 1}');
      expect(
        () => migrate(db, financeMigrations),
        throwsA(isA<SchemaTooNewException>()),
      );
      db.close();
    });

    test('versions are contiguous from 1', () {
      for (var i = 0; i < financeMigrations.length; i++) {
        expect(financeMigrations[i].version, i + 1);
      }
    });
  });
}
