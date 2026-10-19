import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:sqlite3/sqlite3.dart';

import '../crypto/data_key.dart';
import '../db/database.dart' as db_util;
import '../db/search_index.dart';
import 'command_effects.dart';
import 'entity_ref.dart';
import 'local_state.dart';
import 'outbox.dart';
import 'review.dart';
import 'workspace.dart';

/// Checks the JSON of one entity type before it is saved; throws to reject.
typedef EntityValidator = void Function(Map<String, Object?> json);

/// Shared internals of an open workspace, used by the store facade, the
/// receipt vault, the sync client and backups. Not part of the public API.
class StoreContext {
  StoreContext({
    required this.directory,
    required this.db,
    required this.dataKey,
    required this.descriptor,
    required this.validators,
    required Map<String, SearchExtractor> extractors,
    required this.now,
  }) : settings = WorkspaceSettings.read(db) {
    state = LocalState(db, settings.currency, extractors: extractors, now: now);
    outbox = Outbox(db, now);
    reviews = ReviewRepository(db, now);
  }

  final Directory directory;
  final Database db;
  final DataKey dataKey;
  final WorkspaceDescriptor descriptor;
  final Map<String, EntityValidator> validators;
  final DateTime Function() now;
  WorkspaceSettings settings;
  late final LocalState state;
  late final Outbox outbox;
  late final ReviewRepository reviews;

  Chart? _chart;
  int _chartVersion = -1;

  Currency get currency => settings.currency;

  /// Runs [action] in one immediate transaction; it is durable when this
  /// returns (WAL with `synchronous = FULL`). Nested calls join the
  /// enclosing transaction.
  T write<T>(T Function() action) =>
      db.autocommit ? db_util.transaction(db, action) : action();

  void reloadSettings() => settings = WorkspaceSettings.read(db);

  /// Accounts and categories as a [Chart], cached until either changes.
  Chart chart() {
    if (_chart == null || _chartVersion != state.chartVersion) {
      _chart = Chart(
        currency: currency,
        accounts: db
            .select('SELECT * FROM accounts WHERE deleted = 0')
            .map(state.accountFromRow),
        categories: db
            .select('SELECT * FROM categories WHERE deleted = 0')
            .map(state.categoryFromRow),
      );
      _chartVersion = state.chartVersion;
    }
    return _chart!;
  }

  SyncCommand newCommand({
    required CommandType type,
    required EntityRef entity,
    required Map<String, Object?> payload,
    int? baseRevision,
  }) => SyncCommand(
    commandId: newId(),
    workspaceId: settings.workspaceId,
    deviceId: settings.deviceId,
    type: type,
    entityType: entity.type,
    entityId: entity.id,
    baseRevision: baseRevision ?? state.revision(entity),
    payload: payload,
  );

  /// Applies [command] locally and appends it to the outbox. Must run
  /// inside [write] so both land in the same transaction (SYNC 01).
  OutboxEntry record(
    SyncCommand command, {
    bool undoable = true,
    String? description,
  }) {
    final before = applyCommand(state, command);
    final seq = outbox.add(
      command,
      before,
      undoable: undoable,
      description: description,
    );
    return outbox.bySeq(seq)!;
  }

  String? syncValue(String key) {
    final rows = db.select('SELECT value FROM sync_state WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void setSyncValue(String key, String? value) => value == null
      ? db.execute('DELETE FROM sync_state WHERE key = ?', [key])
      : db.execute(
          'INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)',
          [key, value],
        );
}
