import 'dart:convert';

import 'package:finance_core/finance_core.dart';

import '../store/command_effects.dart';
import '../store/entity_ref.dart';
import '../store/local_state.dart';
import '../store/outbox.dart';
import '../store/review.dart';
import '../store/store_context.dart';
import '../vault/asset_record.dart';
import '../vault/receipt_vault.dart';

/// Keys in `sync_state`.
abstract final class SyncKeys {
  static const cursor = 'cursor';
  static const lastPullAt = 'lastPullAt';
  static const lastPushAt = 'lastPushAt';
  static const rebuild = 'rebuild';
}

/// The local half of synchronisation: choosing what to push, recording
/// results, and applying the change feed and snapshots. It never performs
/// network I/O, and every method runs in one local transaction.
class SyncEngine {
  SyncEngine(this.ctx, this.vault);

  final StoreContext ctx;
  final ReceiptVault vault;

  LocalState get _state => ctx.state;
  Outbox get _outbox => ctx.outbox;

  // Push -----------------------------------------------------------------

  /// The longest prefix of pending commands, at most [max], in which no two
  /// commands touch the same entity. Later commands for an entity wait for
  /// the earlier one's revision so a device never conflicts with itself.
  List<OutboxEntry> nextBatch(int max) {
    final batch = <OutboxEntry>[];
    final keys = <EntityRef>{};
    for (final entry in _outbox.pending(limit: max)) {
      if (entry.keys.any(keys.contains)) break;
      batch.add(entry);
      keys.addAll(entry.keys);
    }
    return batch;
  }

  /// Counts an attempt before sending, so a command that may have reached
  /// the server can no longer be undone locally.
  void markSending(List<OutboxEntry> batch) =>
      ctx.write(() => _outbox.recordAttempt(batch.map((e) => e.seq)));

  void markSendFailed(List<OutboxEntry> batch, Object error) =>
      ctx.write(() => _outbox.recordError(batch.map((e) => e.seq), '$error'));

  /// Records per-command results (SYNC 02, SYNC 03).
  PushTally applyResults(List<OutboxEntry> batch, List<CommandResult> results) {
    if (results.length != batch.length) {
      throw FormatException(
        'Expected ${batch.length} results, got ${results.length}',
      );
    }
    final tally = PushTally();
    ctx.write(() {
      for (var i = 0; i < batch.length; i++) {
        final entry = _outbox.bySeq(batch[i].seq)!;
        final result = results[i];
        if (result.commandId != entry.command.commandId) {
          throw FormatException('Result order does not match the batch');
        }
        if (entry.status != OutboxStatus.pending) continue;
        switch (result.status) {
          case CommandStatus.applied:
          case CommandStatus.previouslyApplied:
            _accepted(entry, result);
            tally.accepted++;
          case CommandStatus.conflict:
            final deleted = result.conflict?.serverState == null;
            _hold(
              entry,
              deleted ? ReviewKind.deletedRemotely : ReviewKind.conflict,
              serverState: result.conflict?.serverState,
              serverRevision: result.conflict?.serverRevision,
              fields: result.conflict?.fields ?? const [],
            );
            tally.conflicts++;
          case CommandStatus.validationFailed:
          case CommandStatus.permissionDenied:
            _hold(
              entry,
              ReviewKind.rejected,
              errors: [
                if (result.status == CommandStatus.permissionDenied)
                  'PERMISSION_DENIED',
                ...result.errors,
              ],
            );
            tally.rejected++;
        }
      }
      ctx.setSyncValue(
        SyncKeys.lastPushAt,
        ctx.now().toUtc().toIso8601String(),
      );
    });
    return tally;
  }

  void _accepted(OutboxEntry entry, CommandResult result) {
    _outbox.setStatus(
      entry.seq,
      OutboxStatus.applied,
      result: {
        'status': result.status.wire,
        'revision': result.revision,
        'cursor': result.cursor,
      },
    );
    final primary = entry.primary;
    final revision = result.revision;
    if (revision != null && _state.snapshot(primary) != null) {
      _state.setRevision(primary, revision);
    }
    // Journals created by a correction start at revision 1 on the server.
    final created = {
      for (final e in entry.before.entries)
        if (e.key != primary && e.value == null) e.key,
    };
    for (final ref in created) {
      if (_state.revision(ref) == 0) _state.setRevision(ref, 1);
    }
    if (revision != null) {
      for (final later in _outbox.pendingFor(primary, afterSeq: entry.seq)) {
        if (later.command.baseRevision == entry.command.baseRevision) {
          _outbox.updateCommand(later.seq, _withBase(later.command, revision));
        }
      }
    }
    for (final ref in created) {
      for (final later in _outbox.pendingFor(ref, afterSeq: entry.seq)) {
        if (later.command.baseRevision == 0) {
          _outbox.updateCommand(later.seq, _withBase(later.command, 1));
        }
      }
    }
  }

  SyncCommand _withBase(SyncCommand c, int base) => SyncCommand(
    commandId: c.commandId,
    workspaceId: c.workspaceId,
    deviceId: c.deviceId,
    type: c.type,
    entityType: c.entityType,
    entityId: c.entityId,
    baseRevision: base,
    schemaVersion: c.schemaVersion,
    payload: c.payload,
  );

  /// Holds [entry] and every later command built on it for review, puts
  /// the local state back, and preserves the proposal beside the server
  /// state. Nothing is resolved by last write wins.
  void _hold(
    OutboxEntry entry,
    ReviewKind kind, {
    Map<String, Object?>? serverState,
    int? serverRevision,
    List<String> fields = const [],
    List<String> errors = const [],
  }) {
    final closure = _outbox.closure(entry);
    final primary = entry.primary;
    final proposal = _state.json(primary);
    _revert(closure);
    if (kind == ReviewKind.conflict && serverState != null) {
      _state.put(primary, serverState, revision: serverRevision);
    } else if (kind == ReviewKind.deletedRemotely) {
      _state.markDeleted(primary, revision: serverRevision);
    }
    _outbox.setStatus(entry.seq, switch (kind) {
      ReviewKind.conflict => OutboxStatus.conflict,
      ReviewKind.rejected => OutboxStatus.rejected,
      ReviewKind.deletedRemotely => OutboxStatus.review,
    });
    for (final later in closure.skip(1)) {
      _outbox.setStatus(later.seq, OutboxStatus.blocked);
    }
    ctx.reviews.add(
      ReviewItem(
        id: newId(),
        kind: kind,
        entity: primary,
        localState: proposal,
        localCommands: [for (final e in closure) e.command],
        serverState: serverState,
        serverRevision: serverRevision,
        fields: fields,
        errors: errors,
        status: ReviewStatus.open,
        createdAt: ctx.now().toUtc(),
      ),
    );
  }

  void _revert(List<OutboxEntry> closure) {
    for (final e in closure.reversed) {
      for (final before in e.before.entries.toList().reversed) {
        _state.restore(before.key, before.value);
      }
    }
  }

  // Pull ---------------------------------------------------------------------

  /// Applies one page of the change feed and advances the cursor, in one
  /// transaction (SYNC 04).
  void applyChanges(List<ChangeRecord> changes, String cursor) => ctx.write(() {
    for (final change in changes) {
      _applyChange(change);
    }
    ctx.setSyncValue(SyncKeys.cursor, cursor);
    ctx.setSyncValue(SyncKeys.lastPullAt, ctx.now().toUtc().toIso8601String());
  });

  void _applyChange(ChangeRecord change) {
    final ref = EntityRef(change.entityType, change.entityId);
    final current = _state.snapshot(ref);
    if (current != null &&
        current.revision > change.revision &&
        !change.deleted) {
      return; // Already newer locally (e.g. from a push result).
    }
    final pending = _outbox.pendingTouching(ref);
    if (change.deleted) {
      if (pending.isNotEmpty) {
        _deletedRemotely(ref, pending.first, change.revision);
      } else {
        _state.markDeleted(ref, revision: change.revision);
      }
      if (ref.type == documentAssetType) vault.applyRemoteDeletion(ref.id);
      return;
    }
    final data = change.data ?? const {};
    _state.put(
      ref,
      data,
      revision: change.revision,
      deleted: false,
      fieldRevisions: _fieldRevisions(current, data, change.revision),
    );
    if (ref.type == documentAssetType) vault.applyRemoteMetadata(data);
    // Pending local proposals stay on top of the new server state.
    for (final entry in pending) {
      final before = applyCommand(_state, entry.command);
      _outbox.updateBefore(entry.seq, {
        for (final e in entry.before.entries)
          e.key: e.key == ref ? before[ref] : e.value,
      });
    }
  }

  Map<String, int> _fieldRevisions(
    EntitySnapshot? previous,
    Map<String, Object?> data,
    int revision,
  ) {
    final old = previous?.json ?? const {};
    return {
      ...?previous?.fieldRevisions,
      for (final e in data.entries)
        if (!old.containsKey(e.key) ||
            jsonEncode(old[e.key]) != jsonEncode(e.value))
          e.key: revision,
    };
  }

  /// The entity was deleted on another device while local commands were
  /// pending: the commands are held for review and never resurrect it
  /// (SYNC 06).
  void _deletedRemotely(EntityRef ref, OutboxEntry first, int? revision) =>
      _hold(first, ReviewKind.deletedRemotely, serverRevision: revision);

  // Snapshot rebuild (cursor expired) ----------------------------------------

  RebuildState? get rebuild {
    final text = ctx.syncValue(SyncKeys.rebuild);
    return text == null
        ? null
        : RebuildState.fromJson(
            (jsonDecode(text) as Map).cast<String, Object?>(),
          );
  }

  void startRebuild() => ctx.write(() {
    if (rebuild != null) return;
    ctx.db.execute('DELETE FROM rebuild_seen');
    ctx.setSyncValue(
      SyncKeys.rebuild,
      jsonEncode(const RebuildState(null, null).toJson()),
    );
  });

  /// Applies one snapshot page; progress is saved so a rebuild interrupted
  /// by a crash or network failure resumes from the next page.
  void applySnapshotPage(
    List<ChangeRecord> entities,
    String? after,
    String? cursor,
  ) => ctx.write(() {
    final state = rebuild!;
    for (final change in entities) {
      _applyChange(change);
      ctx.db.execute(
        'INSERT OR IGNORE INTO rebuild_seen (entity_type, entity_id) '
        'VALUES (?, ?)',
        [change.entityType, change.entityId],
      );
    }
    ctx.setSyncValue(
      SyncKeys.rebuild,
      jsonEncode(RebuildState(after, state.cursor ?? cursor).toJson()),
    );
  });

  /// Removes server-known entities missing from the snapshot (deleted while
  /// this device was away) and resumes the change feed. Pending commands
  /// against them go to review; receipt files are never deleted here.
  int finishRebuild() => ctx.write(() {
    final state = rebuild!;
    var held = 0;
    const tables = {
      EntityTypes.journal: 'journals',
      EntityTypes.account: 'accounts',
      EntityTypes.category: 'categories',
    };
    final missing = <EntityRef>[];
    for (final MapEntry(key: type, value: table) in tables.entries) {
      missing.addAll(
        ctx.db
            .select(
              'SELECT id FROM $table t WHERE revision > 0 AND deleted = 0 '
              'AND NOT EXISTS (SELECT 1 FROM rebuild_seen s '
              'WHERE s.entity_type = ? AND s.entity_id = t.id)',
              [type],
            )
            .map((r) => EntityRef(type, r['id'] as String)),
      );
    }
    missing.addAll(
      ctx.db
          .select(
            'SELECT entity_type, id FROM entities e WHERE revision > 0 '
            'AND deleted = 0 AND NOT EXISTS (SELECT 1 FROM rebuild_seen s '
            'WHERE s.entity_type = e.entity_type AND s.entity_id = e.id)',
          )
          .map((r) => EntityRef(r['entity_type'] as String, r['id'] as String)),
    );
    for (final ref in missing) {
      final pending = _outbox.pendingTouching(ref);
      if (pending.isNotEmpty) {
        _deletedRemotely(ref, pending.first, null);
        held++;
      } else {
        _state.markDeleted(ref);
      }
    }
    ctx.db.execute('DELETE FROM rebuild_seen');
    ctx.setSyncValue(SyncKeys.cursor, state.cursor ?? '');
    ctx.setSyncValue(SyncKeys.rebuild, null);
    return held;
  });
}

class PushTally {
  int accepted = 0;
  int conflicts = 0;
  int rejected = 0;
}

/// Progress of a snapshot rebuild, persisted in `sync_state`.
class RebuildState {
  const RebuildState(this.after, this.cursor);

  factory RebuildState.fromJson(Map<String, Object?> json) =>
      RebuildState(json['after'] as String?, json['cursor'] as String?);

  /// Last entity key applied; the next page starts after it.
  final String? after;

  /// Feed cursor taken when the snapshot started.
  final String? cursor;

  Map<String, Object?> toJson() => {'after': after, 'cursor': cursor};
}
