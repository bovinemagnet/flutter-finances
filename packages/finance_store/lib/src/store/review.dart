import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import 'entity_ref.dart';

/// Why local changes are waiting for the user (SYNC 03, SYNC 06).
enum ReviewKind {
  /// The server changed the entity after the revision the edit was based on.
  conflict,

  /// The server rejected the command (`validation_failed` or
  /// `permission_denied`).
  rejected,

  /// The entity was deleted on another device; the local edit is held and
  /// never applied automatically, so nothing is resurrected.
  deletedRemotely,
}

enum ReviewStatus { open, resolved, dismissed }

/// A local proposal that could not be applied, kept beside the server state
/// so the user can compare them and choose or combine (SYNC 03).
@immutable
class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.kind,
    required this.entity,
    required this.localState,
    required this.localCommands,
    required this.serverState,
    required this.serverRevision,
    required this.fields,
    required this.errors,
    required this.status,
    required this.createdAt,
    this.resolution,
  });

  final String id;
  final ReviewKind kind;
  final EntityRef entity;

  /// The entity as the user last saw it locally, including the proposal.
  final Map<String, Object?>? localState;

  /// The proposal itself: the held commands, oldest first.
  final List<SyncCommand> localCommands;

  /// Canonical server state, or null when the entity is deleted remotely.
  final Map<String, Object?>? serverState;
  final int? serverRevision;

  /// Fields the server reported as conflicting.
  final List<String> fields;
  final List<String> errors;
  final ReviewStatus status;
  final DateTime createdAt;

  /// How it was settled, for example the id of the resolving command.
  final String? resolution;
}

class ReviewRepository {
  ReviewRepository(this.db, this.now);

  final Database db;
  final DateTime Function() now;

  void add(ReviewItem item) => db.execute(
    'INSERT INTO conflicts (id, kind, command_id, entity_type, entity_id, '
    'local_json, server_json, server_revision, fields_json, errors_json, '
    'command_ids_json, status, created_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      item.id,
      item.kind.name,
      item.localCommands.isEmpty ? null : item.localCommands.first.commandId,
      item.entity.type,
      item.entity.id,
      jsonEncode({
        'state': item.localState,
        'commands': [for (final c in item.localCommands) c.toJson()],
      }),
      item.serverState == null ? null : jsonEncode(item.serverState),
      item.serverRevision,
      jsonEncode(item.fields),
      jsonEncode(item.errors),
      jsonEncode([for (final c in item.localCommands) c.commandId]),
      item.status.name,
      item.createdAt.toUtc().toIso8601String(),
    ],
  );

  ReviewItem _fromRow(Row row) {
    final local = jsonDecode(row['local_json'] as String) as Map;
    final server = row['server_json'] as String?;
    return ReviewItem(
      id: row['id'] as String,
      kind: ReviewKind.values.byName(row['kind'] as String),
      entity: EntityRef(
        row['entity_type'] as String,
        row['entity_id'] as String,
      ),
      localState: (local['state'] as Map?)?.cast<String, Object?>(),
      localCommands: [
        for (final c
            in (local['commands'] as List).cast<Map<String, Object?>>())
          SyncCommand.fromJson(c.cast<String, Object?>()),
      ],
      serverState: server == null
          ? null
          : (jsonDecode(server) as Map).cast<String, Object?>(),
      serverRevision: row['server_revision'] as int?,
      fields: (jsonDecode(row['fields_json'] as String) as List).cast<String>(),
      errors: (jsonDecode(row['errors_json'] as String) as List).cast<String>(),
      status: ReviewStatus.values.byName(row['status'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      resolution: row['resolution'] as String?,
    );
  }

  List<ReviewItem> open() => db
      .select(
        "SELECT * FROM conflicts WHERE status = 'open' ORDER BY created_at",
      )
      .map(_fromRow)
      .toList();

  ReviewItem? byId(String id) {
    final rows = db.select('SELECT * FROM conflicts WHERE id = ?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  bool hasOpen(EntityRef ref) => db.select(
    "SELECT 1 FROM conflicts WHERE status = 'open' AND entity_type = ? "
    'AND entity_id = ? LIMIT 1',
    [ref.type, ref.id],
  ).isNotEmpty;

  void close(String id, ReviewStatus status, String? resolution) => db.execute(
    'UPDATE conflicts SET status = ?, resolution = ?, resolved_at = ? '
    'WHERE id = ?',
    [status.name, resolution, now().toUtc().toIso8601String(), id],
  );
}
