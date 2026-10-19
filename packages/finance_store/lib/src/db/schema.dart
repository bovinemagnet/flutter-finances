import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';
import 'search_index.dart';

/// Every schema version the application has shipped, oldest first.
///
/// Never edit a released migration; append a new one. Each runs in its own
/// transaction (see [migrate]).
final List<Migration> financeMigrations = List.unmodifiable([
  Migration(1, 'core ledger, generic entities, outbox and sync state', _v1),
  Migration(2, 'receipt vault assets', _v2),
  Migration(3, 'full-text search index', _v3),
]);

final int latestSchemaVersion = financeMigrations.last.version;

void _v1(Database db) {
  db.execute('''
    CREATE TABLE workspace (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      workspace_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      currency TEXT NOT NULL,
      currency_exponent INTEGER NOT NULL,
      timezone TEXT NOT NULL,
      locale TEXT NOT NULL,
      sync_mode TEXT NOT NULL CHECK (sync_mode IN ('local', 'synced')),
      created_at TEXT NOT NULL
    );

    CREATE TABLE accounts (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      include_in_budget INTEGER NOT NULL,
      include_in_forecast INTEGER NOT NULL,
      include_in_net_worth INTEGER NOT NULL,
      archived INTEGER NOT NULL,
      data_source TEXT NOT NULL,
      last_reconciled_on TEXT,
      revision INTEGER NOT NULL DEFAULT 0,
      field_revisions_json TEXT NOT NULL DEFAULT '{}',
      deleted INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE categories (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('income', 'expense')),
      parent_id TEXT,
      archived INTEGER NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0,
      field_revisions_json TEXT NOT NULL DEFAULT '{}',
      deleted INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE journals (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      status TEXT NOT NULL
        CHECK (status IN ('draft', 'pending', 'posted', 'reversed')),
      effective_date TEXT NOT NULL,
      entered_at TEXT NOT NULL,
      currency TEXT NOT NULL,
      account_id TEXT,
      counter_account_id TEXT,
      amount_minor INTEGER,
      payee TEXT,
      notes TEXT,
      tags_json TEXT NOT NULL DEFAULT '[]',
      refund_of TEXT,
      reversal_of TEXT,
      replaces TEXT,
      revision INTEGER NOT NULL DEFAULT 0,
      deleted INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX journals_effective_date ON journals (effective_date);
    CREATE INDEX journals_status_date ON journals (status, effective_date);
    CREATE INDEX journals_account_date ON journals (account_id, effective_date);
    CREATE INDEX journals_amount ON journals (amount_minor);
    CREATE INDEX journals_reversal_of ON journals (reversal_of);
    CREATE INDEX journals_replaces ON journals (replaces);

    CREATE TABLE postings (
      journal_id TEXT NOT NULL REFERENCES journals (id) ON DELETE CASCADE,
      seq INTEGER NOT NULL,
      account_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      PRIMARY KEY (journal_id, seq)
    ) WITHOUT ROWID;
    CREATE INDEX postings_account ON postings (account_id, journal_id);

    CREATE TABLE entities (
      entity_type TEXT NOT NULL,
      id TEXT NOT NULL,
      json TEXT NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0,
      field_revisions_json TEXT NOT NULL DEFAULT '{}',
      deleted INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (entity_type, id)
    ) WITHOUT ROWID;

    CREATE TABLE outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      command_id TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      command_json TEXT NOT NULL,
      undo_json TEXT,
      undoable INTEGER NOT NULL DEFAULT 1,
      description TEXT,
      status TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      result_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX outbox_status ON outbox (status, seq);
    CREATE INDEX outbox_entity ON outbox (entity_type, entity_id, status);

    CREATE TABLE outbox_keys (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      seq INTEGER NOT NULL REFERENCES outbox (seq) ON DELETE CASCADE,
      PRIMARY KEY (entity_type, entity_id, seq)
    ) WITHOUT ROWID;
    CREATE INDEX outbox_keys_seq ON outbox_keys (seq);

    CREATE TABLE sync_state (
      key TEXT PRIMARY KEY,
      value TEXT
    );

    CREATE TABLE rebuild_seen (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      PRIMARY KEY (entity_type, entity_id)
    ) WITHOUT ROWID;

    CREATE TABLE conflicts (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      command_id TEXT,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      local_json TEXT,
      server_json TEXT,
      server_revision INTEGER,
      fields_json TEXT NOT NULL DEFAULT '[]',
      errors_json TEXT NOT NULL DEFAULT '[]',
      command_ids_json TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      resolved_at TEXT,
      resolution TEXT
    );
    CREATE INDEX conflicts_status ON conflicts (status);
  ''');
}

void _v2(Database db) {
  db.execute('''
    CREATE TABLE assets (
      id TEXT PRIMARY KEY,
      owner_type TEXT NOT NULL,
      owner_id TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('source', 'derivative', 'preview')),
      content_type TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      stored_bytes INTEGER NOT NULL DEFAULT 0,
      local_state TEXT NOT NULL
        CHECK (local_state IN ('present', 'evicted', 'remote')),
      upload_state TEXT NOT NULL CHECK (upload_state IN
        ('not_required', 'pending', 'uploading', 'uploaded', 'failed')),
      upload_attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      cloud_confirmed_at TEXT,
      created_at TEXT NOT NULL,
      last_accessed_at TEXT
    );
    CREATE INDEX assets_owner ON assets (owner_type, owner_id);
    CREATE INDEX assets_upload ON assets (upload_state);
  ''');
}

void _v3(Database db) {
  db.execute('''
    CREATE TABLE search_docs (
      doc_id INTEGER PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      UNIQUE (entity_type, entity_id)
    );
    CREATE VIRTUAL TABLE search_index USING fts5 (
      payee, notes, tags, body,
      tokenize = 'unicode61 remove_diacritics 2'
    );
  ''');
  for (final row in db.select('SELECT id FROM journals WHERE deleted = 0')) {
    reindexJournal(db, row['id'] as String);
  }
  final entities = db.select(
    'SELECT entity_type, id, json FROM entities '
    'WHERE deleted = 0 AND entity_type != ?',
    [journalAnnotationType],
  );
  for (final row in entities) {
    putSearchDocument(
      db,
      row['entity_type'] as String,
      row['id'] as String,
      defaultSearchDocument(
        (jsonDecode(row['json'] as String) as Map).cast<String, Object?>(),
      ),
    );
  }
}
