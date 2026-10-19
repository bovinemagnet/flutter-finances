import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/search_index.dart';
import 'entity_ref.dart';

/// The stored state of one entity, used for undo images, rollbacks and
/// overlays. A null snapshot means the row does not exist.
@immutable
class EntitySnapshot {
  const EntitySnapshot(
    this.json, {
    required this.revision,
    this.deleted = false,
    this.fieldRevisions = const {},
  });

  factory EntitySnapshot.fromJson(Map<String, Object?> json) => EntitySnapshot(
    (json['json'] as Map).cast<String, Object?>(),
    revision: json['revision'] as int,
    deleted: json['deleted'] as bool,
    fieldRevisions: (json['fieldRevisions'] as Map? ?? const {})
        .cast<String, int>(),
  );

  final Map<String, Object?> json;
  final int revision;
  final bool deleted;
  final Map<String, int> fieldRevisions;

  Map<String, Object?> toJson() => {
    'json': json,
    'revision': revision,
    'deleted': deleted,
    'fieldRevisions': fieldRevisions,
  };
}

/// Reads and writes entities of every type as their sync JSON.
///
/// Journals, accounts and categories go to typed tables so balances can be
/// aggregated in SQL; every other entity type goes to the generic
/// `entities` table. All methods must run inside the caller's transaction.
class LocalState {
  LocalState(
    this.db,
    this.currency, {
    required this.extractors,
    required this.now,
  });

  final Database db;
  final Currency currency;
  final Map<String, SearchExtractor> extractors;
  final DateTime Function() now;

  /// Incremented whenever an account or category changes.
  int chartVersion = 0;

  String _now() => now().toUtc().toIso8601String();

  EntitySnapshot? snapshot(EntityRef ref) => switch (ref.type) {
    EntityTypes.journal => _journalSnapshot(ref.id),
    EntityTypes.account => _accountSnapshot(ref.id),
    EntityTypes.category => _categorySnapshot(ref.id),
    _ => _genericSnapshot(ref),
  };

  /// Current JSON of a live (not deleted) entity.
  Map<String, Object?>? json(EntityRef ref) {
    final s = snapshot(ref);
    return s == null || s.deleted ? null : s.json;
  }

  /// Last server revision of the entity, 0 when unknown.
  int revision(EntityRef ref) => snapshot(ref)?.revision ?? 0;

  /// Writes [json] as the entity's state. A null [revision] keeps the
  /// stored revision.
  void put(
    EntityRef ref,
    Map<String, Object?> json, {
    int? revision,
    bool deleted = false,
    Map<String, int>? fieldRevisions,
  }) {
    final existing = (revision == null || fieldRevisions == null)
        ? snapshot(ref)
        : null;
    final rev = revision ?? existing?.revision ?? 0;
    final fields = fieldRevisions ?? existing?.fieldRevisions ?? const {};
    switch (ref.type) {
      case EntityTypes.journal:
        _putJournal(ref.id, json, rev, deleted);
      case EntityTypes.account:
        _putAccount(ref.id, json, rev, deleted, fields);
      case EntityTypes.category:
        _putCategory(ref.id, json, rev, deleted, fields);
      default:
        _putGeneric(ref, json, rev, deleted, fields);
    }
  }

  /// Marks the entity deleted (a tombstone), keeping its last JSON.
  void markDeleted(EntityRef ref, {int? revision}) {
    final s = snapshot(ref);
    put(
      ref,
      s?.json ?? {'id': ref.id},
      revision: revision ?? s?.revision ?? 0,
      deleted: true,
    );
  }

  void setRevision(EntityRef ref, int revision) {
    final table = _table(ref.type);
    if (table == 'entities') {
      db.execute(
        'UPDATE entities SET revision = ? WHERE entity_type = ? AND id = ?',
        [revision, ref.type, ref.id],
      );
    } else {
      db.execute('UPDATE $table SET revision = ? WHERE id = ?', [
        revision,
        ref.id,
      ]);
    }
  }

  /// Puts back a snapshot, or removes the row when [snapshot] is null.
  void restore(EntityRef ref, EntitySnapshot? snapshot) {
    if (snapshot == null) {
      remove(ref);
    } else {
      put(
        ref,
        snapshot.json,
        revision: snapshot.revision,
        deleted: snapshot.deleted,
        fieldRevisions: snapshot.fieldRevisions,
      );
    }
  }

  /// Physically removes a row, for entities that never reached the server.
  void remove(EntityRef ref) {
    final table = _table(ref.type);
    if (table == 'entities') {
      db.execute('DELETE FROM entities WHERE entity_type = ? AND id = ?', [
        ref.type,
        ref.id,
      ]);
    } else {
      db.execute('DELETE FROM $table WHERE id = ?', [ref.id]);
    }
    _afterWrite(ref, null, true);
  }

  String _table(String type) => switch (type) {
    EntityTypes.journal => 'journals',
    EntityTypes.account => 'accounts',
    EntityTypes.category => 'categories',
    _ => 'entities',
  };

  void _afterWrite(EntityRef ref, Map<String, Object?>? json, bool deleted) {
    switch (ref.type) {
      case EntityTypes.journal:
      case journalAnnotationType:
        reindexJournal(db, ref.id);
      case EntityTypes.account:
      case EntityTypes.category:
        chartVersion++;
      default:
        final extract = extractors[ref.type] ?? defaultSearchDocument;
        putSearchDocument(
          db,
          ref.type,
          ref.id,
          deleted || json == null ? null : extract(json),
        );
    }
  }

  // Journals -------------------------------------------------------------

  EntitySnapshot? _journalSnapshot(String id) {
    final rows = db.select('SELECT * FROM journals WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final postings = postingsFor([id])[id] ?? const [];
    return EntitySnapshot(
      journalToJson(journalFromRow(rows.first, postings)),
      revision: rows.first['revision'] as int,
      deleted: rows.first['deleted'] == 1,
    );
  }

  void _putJournal(
    String id,
    Map<String, Object?> json,
    int revision,
    bool deleted,
  ) {
    final journal = journalFromJson(json, currency);
    if (journal.id != id) {
      throw ArgumentError('Journal id ${journal.id} does not match $id');
    }
    db.execute(
      'INSERT OR REPLACE INTO journals (id, type, status, effective_date, '
      'entered_at, currency, account_id, counter_account_id, amount_minor, '
      'payee, notes, tags_json, refund_of, reversal_of, replaces, revision, '
      'deleted, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        journal.type.name,
        journal.status.name,
        journal.effectiveDate.toString(),
        journal.enteredAt.toUtc().toIso8601String(),
        currency.code,
        journal.accountId,
        journal.counterAccountId,
        journal.amount?.minor,
        journal.payee,
        journal.notes,
        jsonEncode(journal.tags.toList()..sort()),
        journal.refundOf,
        journal.reversalOf,
        journal.replaces,
        revision,
        deleted ? 1 : 0,
        _now(),
      ],
    );
    db.execute('DELETE FROM postings WHERE journal_id = ?', [id]);
    final ledgerState = deleted
        ? 'none'
        : journal.status.inPostedLedger
        ? 'posted'
        : journal.status == JournalStatus.pending
        ? 'pending'
        : 'none';
    final insert = db.prepare(
      'INSERT INTO postings (journal_id, seq, account_id, amount_minor, '
      'ledger_state, effective_date) VALUES (?, ?, ?, ?, ?, ?)',
    );
    try {
      for (var i = 0; i < journal.postings.length; i++) {
        final p = journal.postings[i];
        insert.execute([
          id,
          i,
          p.ledgerAccountId,
          p.amount.minor,
          ledgerState,
          journal.effectiveDate.toString(),
        ]);
      }
    } finally {
      insert.close();
    }
    _afterWrite(EntityRef(EntityTypes.journal, id), json, deleted);
  }

  /// Postings of the given journals, in their original order.
  Map<String, List<Posting>> postingsFor(Iterable<String> journalIds) {
    final ids = journalIds.toList();
    final result = <String, List<Posting>>{};
    const chunk = 500;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(
        i,
        i + chunk > ids.length ? ids.length : i + chunk,
      );
      final rows = db.select(
        'SELECT journal_id, account_id, amount_minor FROM postings '
        'WHERE journal_id IN (${List.filled(part.length, '?').join(',')}) '
        'ORDER BY journal_id, seq',
        part,
      );
      for (final row in rows) {
        result
            .putIfAbsent(row['journal_id'] as String, () => [])
            .add(
              Posting(
                row['account_id'] as String,
                Money(row['amount_minor'] as int, currency),
              ),
            );
      }
    }
    return result;
  }

  Journal journalFromRow(Row row, List<Posting> postings) {
    Money? money(Object? minor) =>
        minor == null ? null : Money(minor as int, currency);
    return Journal(
      id: row['id'] as String,
      type: TransactionType.values.byName(row['type'] as String),
      status: JournalStatus.values.byName(row['status'] as String),
      effectiveDate: LocalDate.parse(row['effective_date'] as String),
      enteredAt: DateTime.parse(row['entered_at'] as String).toUtc(),
      postings: postings,
      accountId: row['account_id'] as String?,
      counterAccountId: row['counter_account_id'] as String?,
      amount: money(row['amount_minor']),
      payee: row['payee'] as String?,
      notes: row['notes'] as String?,
      tags: decodeTags(row['tags_json']).toSet(),
      refundOf: row['refund_of'] as String?,
      reversalOf: row['reversal_of'] as String?,
      replaces: row['replaces'] as String?,
    );
  }

  // Accounts and categories ------------------------------------------------

  EntitySnapshot? _accountSnapshot(String id) {
    final rows = db.select('SELECT * FROM accounts WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return EntitySnapshot(
      accountToJson(accountFromRow(row)),
      revision: row['revision'] as int,
      deleted: row['deleted'] == 1,
      fieldRevisions: _fieldRevisions(row['field_revisions_json']),
    );
  }

  Account accountFromRow(Row row) => Account(
    id: row['id'] as String,
    name: row['name'] as String,
    type: AccountType.values.byName(row['type'] as String),
    includeInBudget: row['include_in_budget'] == 1,
    includeInForecast: row['include_in_forecast'] == 1,
    includeInNetWorth: row['include_in_net_worth'] == 1,
    archived: row['archived'] == 1,
    dataSource: row['data_source'] as String,
    lastReconciledOn: row['last_reconciled_on'] == null
        ? null
        : LocalDate.parse(row['last_reconciled_on'] as String),
  );

  void _putAccount(
    String id,
    Map<String, Object?> json,
    int revision,
    bool deleted,
    Map<String, int> fields,
  ) {
    final a = accountFromJson({...json, 'id': id});
    db.execute(
      'INSERT OR REPLACE INTO accounts (id, name, type, include_in_budget, '
      'include_in_forecast, include_in_net_worth, archived, data_source, '
      'last_reconciled_on, revision, field_revisions_json, deleted, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        a.id,
        a.name,
        a.type.name,
        a.includeInBudget ? 1 : 0,
        a.includeInForecast ? 1 : 0,
        a.includeInNetWorth ? 1 : 0,
        a.archived ? 1 : 0,
        a.dataSource,
        a.lastReconciledOn?.toString(),
        revision,
        jsonEncode(fields),
        deleted ? 1 : 0,
        _now(),
      ],
    );
    _afterWrite(EntityRef(EntityTypes.account, id), json, deleted);
  }

  EntitySnapshot? _categorySnapshot(String id) {
    final rows = db.select('SELECT * FROM categories WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return EntitySnapshot(
      categoryToJson(categoryFromRow(row)),
      revision: row['revision'] as int,
      deleted: row['deleted'] == 1,
      fieldRevisions: _fieldRevisions(row['field_revisions_json']),
    );
  }

  Category categoryFromRow(Row row) => Category(
    id: row['id'] as String,
    name: row['name'] as String,
    kind: CategoryKind.values.byName(row['kind'] as String),
    parentId: row['parent_id'] as String?,
    archived: row['archived'] == 1,
  );

  void _putCategory(
    String id,
    Map<String, Object?> json,
    int revision,
    bool deleted,
    Map<String, int> fields,
  ) {
    final c = categoryFromJson({...json, 'id': id});
    db.execute(
      'INSERT OR REPLACE INTO categories (id, name, kind, parent_id, '
      'archived, revision, field_revisions_json, deleted, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        c.id,
        c.name,
        c.kind.name,
        c.parentId,
        c.archived ? 1 : 0,
        revision,
        jsonEncode(fields),
        deleted ? 1 : 0,
        _now(),
      ],
    );
    _afterWrite(EntityRef(EntityTypes.category, id), json, deleted);
  }

  // Generic entities ---------------------------------------------------------

  EntitySnapshot? _genericSnapshot(EntityRef ref) {
    final rows = db.select(
      'SELECT * FROM entities WHERE entity_type = ? AND id = ?',
      [ref.type, ref.id],
    );
    if (rows.isEmpty) return null;
    return EntitySnapshot(
      (jsonDecode(rows.first['json'] as String) as Map).cast<String, Object?>(),
      revision: rows.first['revision'] as int,
      deleted: rows.first['deleted'] == 1,
      fieldRevisions: _fieldRevisions(rows.first['field_revisions_json']),
    );
  }

  EntityRecord recordFromRow(Row row) => EntityRecord(
    ref: EntityRef(row['entity_type'] as String, row['id'] as String),
    json: (jsonDecode(row['json'] as String) as Map).cast<String, Object?>(),
    revision: row['revision'] as int,
    deleted: row['deleted'] == 1,
    updatedAt: DateTime.parse(row['updated_at'] as String),
    fieldRevisions: _fieldRevisions(row['field_revisions_json']),
  );

  void _putGeneric(
    EntityRef ref,
    Map<String, Object?> json,
    int revision,
    bool deleted,
    Map<String, int> fields,
  ) {
    db.execute(
      'INSERT OR REPLACE INTO entities (entity_type, id, json, revision, '
      'field_revisions_json, deleted, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        ref.type,
        ref.id,
        jsonEncode(json),
        revision,
        jsonEncode(fields),
        deleted ? 1 : 0,
        _now(),
      ],
    );
    _afterWrite(ref, json, deleted);
  }

  Map<String, int> _fieldRevisions(Object? text) => text == null
      ? const {}
      : (jsonDecode(text as String) as Map).cast<String, int>();
}
