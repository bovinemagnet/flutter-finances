import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import 'entity_ref.dart';
import 'local_state.dart';

/// Lifecycle of a locally recorded command.
enum OutboxStatus {
  /// Saved locally and not yet accepted by the server.
  pending,

  /// Accepted (`applied` or `previously_applied`).
  applied,

  /// Rejected for a revision conflict; see the review item.
  conflict,

  /// Rejected by validation or permissions; see the review item.
  rejected,

  /// Built on a conflicting or rejected command, held for review.
  blocked,

  /// Targets an entity deleted remotely; held for review, never resent.
  review,

  /// Dropped by the user while resolving a review item.
  discarded,
}

/// One command in the durable outbox with its undo images.
@immutable
class OutboxEntry {
  const OutboxEntry({
    required this.seq,
    required this.command,
    required this.status,
    required this.attempts,
    required this.before,
    required this.undoable,
    required this.createdAt,
    this.lastError,
    this.description,
    this.result,
  });

  final int seq;
  final SyncCommand command;
  final OutboxStatus status;

  /// How many times the command has been sent. A sent command may have been
  /// applied by the server, so it can no longer be undone locally.
  final int attempts;

  /// State of every affected entity before the command, in order.
  final Map<EntityRef, EntitySnapshot?> before;
  final bool undoable;
  final DateTime createdAt;
  final String? lastError;
  final String? description;
  final Map<String, Object?>? result;

  EntityRef get primary => EntityRef(command.entityType, command.entityId);
  Set<EntityRef> get keys => before.keys.toSet();
}

/// The durable outbox (SYNC 01). Commands keep their original order and
/// `commandId` for their whole life, so a retry is always idempotent.
class Outbox {
  Outbox(this.db, this.now);

  final Database db;
  final DateTime Function() now;

  String _now() => now().toUtc().toIso8601String();

  int add(
    SyncCommand command,
    Map<EntityRef, EntitySnapshot?> before, {
    bool undoable = true,
    String? description,
  }) {
    final at = _now();
    db.execute(
      'INSERT INTO outbox (command_id, type, entity_type, entity_id, '
      'command_json, undo_json, undoable, description, status, created_at, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        command.commandId,
        command.type.wire,
        command.entityType,
        command.entityId,
        jsonEncode(command.toJson()),
        _encodeBefore(before),
        undoable ? 1 : 0,
        description,
        OutboxStatus.pending.name,
        at,
        at,
      ],
    );
    final seq = db.lastInsertRowId;
    for (final ref in before.keys) {
      db.execute(
        'INSERT OR IGNORE INTO outbox_keys (entity_type, entity_id, seq) '
        'VALUES (?, ?, ?)',
        [ref.type, ref.id, seq],
      );
    }
    return seq;
  }

  String _encodeBefore(Map<EntityRef, EntitySnapshot?> before) => jsonEncode([
    for (final e in before.entries)
      {'ref': e.key.key, 'before': e.value?.toJson()},
  ]);

  OutboxEntry _fromRow(Row row) {
    final before = <EntityRef, EntitySnapshot?>{};
    final undo = row['undo_json'] as String?;
    if (undo != null) {
      for (final item
          in (jsonDecode(undo) as List).cast<Map<String, Object?>>()) {
        final snap = item['before'] as Map?;
        before[EntityRef.parse(item['ref'] as String)] = snap == null
            ? null
            : EntitySnapshot.fromJson(snap.cast<String, Object?>());
      }
    }
    final result = row['result_json'] as String?;
    return OutboxEntry(
      seq: row['seq'] as int,
      command: SyncCommand.fromJson(
        (jsonDecode(row['command_json'] as String) as Map)
            .cast<String, Object?>(),
      ),
      status: OutboxStatus.values.byName(row['status'] as String),
      attempts: row['attempts'] as int,
      before: before,
      undoable: row['undoable'] == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
      lastError: row['last_error'] as String?,
      description: row['description'] as String?,
      result: result == null
          ? null
          : (jsonDecode(result) as Map).cast<String, Object?>(),
    );
  }

  List<OutboxEntry> _query(String where, [List<Object?> args = const []]) => db
      .select('SELECT * FROM outbox WHERE $where', args)
      .map(_fromRow)
      .toList();

  List<OutboxEntry> pending({int? limit}) => _query(
    "status = 'pending' ORDER BY seq${limit == null ? '' : ' LIMIT $limit'}",
  );

  List<OutboxEntry> withStatus(OutboxStatus status) =>
      _query('status = ? ORDER BY seq', [status.name]);

  int get pendingCount =>
      db
              .select("SELECT count(*) FROM outbox WHERE status = 'pending'")
              .first
              .columnAt(0)
          as int;

  OutboxEntry? bySeq(int seq) {
    final rows = _query('seq = ?', [seq]);
    return rows.isEmpty ? null : rows.first;
  }

  OutboxEntry? byCommandId(String commandId) {
    final rows = _query('command_id = ?', [commandId]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The most recently recorded command that is still pending.
  OutboxEntry? latestPending() {
    final rows = _query("status = 'pending' ORDER BY seq DESC LIMIT 1");
    return rows.isEmpty ? null : rows.first;
  }

  /// Pending commands affecting [ref], oldest first.
  List<OutboxEntry> pendingTouching(EntityRef ref) => _query(
    "status = 'pending' AND seq IN (SELECT seq FROM outbox_keys "
    'WHERE entity_type = ? AND entity_id = ?) ORDER BY seq',
    [ref.type, ref.id],
  );

  bool touchesPending(EntityRef ref) => db.select(
    'SELECT 1 FROM outbox_keys WHERE entity_type = ? AND entity_id = ? '
    'LIMIT 1',
    [ref.type, ref.id],
  ).isNotEmpty;

  Set<EntityRef> pendingKeys() => db
      .select('SELECT DISTINCT entity_type, entity_id FROM outbox_keys')
      .map(
        (r) => EntityRef(r['entity_type'] as String, r['entity_id'] as String),
      )
      .toSet();

  /// [start] and every later pending command that shares an entity with it,
  /// transitively. Reverting or holding [start] must include all of them.
  ///
  /// Candidates are found through the indexed `outbox_keys` table, so the
  /// cost does not grow with the number of unrelated pending commands.
  List<OutboxEntry> closure(OutboxEntry start) {
    final candidates = <int>{};
    final seen = <EntityRef>{};
    final queue = [...start.keys];
    while (queue.isNotEmpty) {
      final key = queue.removeLast();
      if (!seen.add(key)) continue;
      final rows = db.select(
        'SELECT seq FROM outbox_keys WHERE entity_type = ? AND entity_id = ? '
        'AND seq > ?',
        [key.type, key.id, start.seq],
      );
      for (final row in rows) {
        final seq = row['seq'] as int;
        if (candidates.add(seq)) queue.addAll(bySeq(seq)!.keys);
      }
    }
    final keys = {...start.keys};
    final result = [start];
    for (final seq in candidates.toList()..sort()) {
      final entry = bySeq(seq)!;
      if (entry.status != OutboxStatus.pending) continue;
      if (entry.keys.any(keys.contains)) {
        result.add(entry);
        keys.addAll(entry.keys);
      }
    }
    return result;
  }

  /// Pending commands whose primary entity is [ref], recorded after
  /// [afterSeq].
  List<OutboxEntry> pendingFor(EntityRef ref, {required int afterSeq}) =>
      _query(
        "status = 'pending' AND entity_type = ? AND entity_id = ? "
        'AND seq > ? ORDER BY seq',
        [ref.type, ref.id, afterSeq],
      );

  /// Moves a command out of `pending`; it then no longer marks its
  /// entities as unsynced.
  void setStatus(
    int seq,
    OutboxStatus status, {
    String? error,
    Map<String, Object?>? result,
  }) {
    db.execute(
      'UPDATE outbox SET status = ?, last_error = COALESCE(?, last_error), '
      'result_json = COALESCE(?, result_json), updated_at = ? WHERE seq = ?',
      [
        status.name,
        error,
        result == null ? null : jsonEncode(result),
        _now(),
        seq,
      ],
    );
    if (status != OutboxStatus.pending) {
      db.execute('DELETE FROM outbox_keys WHERE seq = ?', [seq]);
    }
  }

  void recordAttempt(Iterable<int> seqs, {String? error}) {
    for (final seq in seqs) {
      db.execute(
        'UPDATE outbox SET attempts = attempts + 1, last_error = ?, '
        'updated_at = ? WHERE seq = ?',
        [error, _now(), seq],
      );
    }
  }

  void recordError(Iterable<int> seqs, String error) {
    for (final seq in seqs) {
      db.execute('UPDATE outbox SET last_error = ? WHERE seq = ?', [
        error,
        seq,
      ]);
    }
  }

  void updateCommand(int seq, SyncCommand command) => db.execute(
    'UPDATE outbox SET command_json = ? WHERE seq = ?',
    [jsonEncode(command.toJson()), seq],
  );

  void updateBefore(int seq, Map<EntityRef, EntitySnapshot?> before) =>
      db.execute('UPDATE outbox SET undo_json = ? WHERE seq = ?', [
        _encodeBefore(before),
        seq,
      ]);

  void delete(int seq) => db.execute('DELETE FROM outbox WHERE seq = ?', [seq]);
}
