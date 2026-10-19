import 'dart:async';
import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../store/finance_store.dart';
import '../store/store_context.dart';
import '../store/workspace.dart';
import '../vault/asset_record.dart';
import 'asset_sync.dart';
import 'remote_workspace.dart';
import 'sync_engine.dart';
import 'transport.dart';

export 'remote_workspace.dart';

class SyncNotEnabledException implements Exception {
  @override
  String toString() =>
      'The workspace is local only; enable sync through a bootstrap preview';
}

/// Enabling sync would merge two workspaces that both hold data.
class WorkspaceMergeRefusedException implements Exception {
  @override
  String toString() =>
      'Both this device and the server workspace hold data; they are never '
      'merged automatically. Restore or start a new workspace instead';
}

class StalePreviewException implements Exception {
  @override
  String toString() => 'The workspace changed since the preview; preview again';
}

enum BootstrapAction {
  /// Upload this device's history to an empty server workspace.
  uploadLocal,

  /// Download the server workspace onto this empty device.
  downloadRemote,

  /// Both are empty.
  startEmpty,

  /// Both hold data; refused.
  mergeRefused,
}

/// What enabling sync will do, shown to the user before confirming
/// (SYNC 01: never merge two existing workspaces automatically).
@immutable
class SyncBootstrapPreview {
  const SyncBootstrapPreview({
    required this.remoteWorkspaceId,
    required this.deviceId,
    required this.localCounts,
    required this.pendingCommands,
    required this.remoteHasData,
    required this.outboxHead,
  });

  final String remoteWorkspaceId;
  final String deviceId;

  /// Live local records by entity type, plus `asset`.
  final Map<String, int> localCounts;

  /// Local commands that will be uploaded in order.
  final int pendingCommands;
  final bool remoteHasData;

  /// Fingerprint of the outbox when the preview was made.
  final int outboxHead;

  bool get localHasData => localCounts.values.any((n) => n > 0);

  BootstrapAction get action => localHasData && remoteHasData
      ? BootstrapAction.mergeRefused
      : localHasData
      ? BootstrapAction.uploadLocal
      : remoteHasData
      ? BootstrapAction.downloadRemote
      : BootstrapAction.startEmpty;
}

@immutable
class PushResult {
  const PushResult({
    required this.sent,
    required this.accepted,
    required this.conflicts,
    required this.rejected,
  });

  final int sent;
  final int accepted;
  final int conflicts;
  final int rejected;
}

@immutable
class PullResult {
  const PullResult({
    required this.changes,
    required this.rebuilt,
    required this.heldForReview,
  });

  final int changes;

  /// The cursor had expired and the workspace was rebuilt from a snapshot.
  final bool rebuilt;

  /// Pending commands against entities deleted while away.
  final int heldForReview;
}

@immutable
class SyncReport {
  const SyncReport(this.pull, this.push, this.uploads);
  final PullResult pull;
  final PushResult push;
  final UploadSummary? uploads;
}

/// Synchronises one workspace with the server (SYNC 02 to SYNC 06).
///
/// A sync pulls first (so a device returning after the tombstone horizon
/// rebuilds before sending anything), pushes the outbox, pulls again for
/// the accepted changes, then uploads receipt files. Calls are serialised.
class SyncClient {
  SyncClient(
    FinanceStore store, {
    required http.Client httpClient,
    required Uri baseUri,
    AccessTokenProvider? accessToken,
    RetryPolicy retry = const RetryPolicy(),
    Duration timeout = const Duration(seconds: 30),
    Sleep? sleep,
    this.batchSize = 500,
    this.pageSize = 500,
    int uploadConcurrency = 2,
  }) : _store = store,
       _ctx = store.context,
       transport = SyncTransport(
         client: httpClient,
         baseUri: baseUri,
         accessToken: accessToken,
         scope: () => _scopeHeaders(store.context),
         retry: retry,
         timeout: timeout,
         sleep: sleep,
       ) {
    engine = SyncEngine(_ctx, store.vault);
    assets = AssetSync(
      ctx: _ctx,
      vault: store.vault,
      transport: transport,
      concurrency: uploadConcurrency,
    );
  }

  final FinanceStore _store;
  final StoreContext _ctx;
  final SyncTransport transport;
  late final SyncEngine engine;
  late final AssetSync assets;

  /// Commands per request; the protocol allows at most 500.
  final int batchSize;
  final int pageSize;

  Future<void> _lock = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Every API call names this device; once synced it also names the
  /// remote workspace, which is then the local workspace id.
  static Map<String, String> _scopeHeaders(StoreContext ctx) {
    final settings = ctx.settings;
    return {
      deviceIdHeader: settings.deviceId,
      if (settings.syncMode == SyncMode.synced)
        workspaceIdHeader: settings.workspaceId,
    };
  }

  void _requireSynced() {
    if (_ctx.settings.syncMode != SyncMode.synced) {
      throw SyncNotEnabledException();
    }
  }

  /// Pull, push, pull, then upload receipt files.
  Future<SyncReport> sync({
    bool uploadAssets = true,
    bool meteredConnection = false,
    void Function(UploadProgress progress)? onUploadProgress,
  }) => _serial(() async {
    _requireSynced();
    final first = await _pull();
    final push = await _push();
    final second = await _pull();
    final uploads = uploadAssets
        ? await assets.uploadPending(
            meteredConnection: meteredConnection,
            onProgress: onUploadProgress,
          )
        : null;
    return SyncReport(
      PullResult(
        changes: first.changes + second.changes,
        rebuilt: first.rebuilt || second.rebuilt,
        heldForReview: first.heldForReview + second.heldForReview,
      ),
      push,
      uploads,
    );
  });

  Future<PushResult> push() => _serial(() async {
    _requireSynced();
    return _push();
  });

  Future<PullResult> pull() => _serial(() async {
    _requireSynced();
    return _pull();
  });

  Future<UploadSummary> uploadAssets({
    bool meteredConnection = false,
    void Function(UploadProgress progress)? onProgress,
  }) => _serial(() async {
    _requireSynced();
    return assets.uploadPending(
      meteredConnection: meteredConnection,
      onProgress: onProgress,
    );
  });

  /// Downloads a remote or evicted asset; throws
  /// [AssetNotYetAvailableException] while its upload is incomplete.
  Future<AssetRecord> downloadAsset(String assetId) =>
      _serial(() => assets.download(assetId));

  Future<PushResult> _push() async {
    var sent = 0;
    final tally = PushTally();
    while (true) {
      final batch = engine.nextBatch(batchSize);
      if (batch.isEmpty) break;
      engine.markSending(batch);
      final Map<String, Object?> response;
      try {
        response = await transport.postJson('/v1/sync/commands', {
          'commands': [for (final e in batch) e.command.toJson()],
        });
      } catch (e) {
        engine.markSendFailed(batch, e);
        rethrow;
      }
      final results = [
        for (final r
            in (response['results'] as List).cast<Map<String, Object?>>())
          CommandResult.fromJson(r.cast<String, Object?>()),
      ];
      final t = engine.applyResults(batch, results);
      sent += batch.length;
      tally
        ..accepted += t.accepted
        ..conflicts += t.conflicts
        ..rejected += t.rejected;
    }
    return PushResult(
      sent: sent,
      accepted: tally.accepted,
      conflicts: tally.conflicts,
      rejected: tally.rejected,
    );
  }

  Future<PullResult> _pull() async {
    if (engine.rebuild != null) return _rebuild();
    var count = 0;
    while (true) {
      final cursor = _ctx.syncValue(SyncKeys.cursor) ?? '';
      final response = await transport.send(
        () async => http.Request(
          'GET',
          transport.resolve('/v1/sync/changes', {
            'cursor': cursor,
            'limit': '$pageSize',
          }),
        )..headers.addAll(await transport.headers()),
        acceptStatus: (s) => s == 410,
      );
      if (response.statusCode == 410) {
        engine.startRebuild();
        final rebuilt = await _rebuild();
        return PullResult(
          changes: count + rebuilt.changes,
          rebuilt: true,
          heldForReview: rebuilt.heldForReview,
        );
      }
      final json = (jsonDecode(response.body) as Map).cast<String, Object?>();
      final changes = _records(json['changes']);
      engine.applyChanges(changes, json['cursor'] as String);
      count += changes.length;
      if (json['hasMore'] != true) break;
    }
    return PullResult(changes: count, rebuilt: false, heldForReview: 0);
  }

  /// Pages `GET /v1/sync/snapshot?after=<entityKey>` from the saved
  /// position, then resumes the feed (SYNC 04, A15).
  Future<PullResult> _rebuild() async {
    var count = 0;
    while (true) {
      final after = engine.rebuild!.after;
      final json = await transport.getJson(
        '/v1/sync/snapshot',
        query: {'after': ?after, 'limit': '$pageSize'},
      );
      final entities = _records(json['changes'] ?? json['entities']);
      final next =
          (json['after'] ?? json['next']) as String? ??
          (entities.isEmpty
              ? after
              : '${entities.last.entityType}:${entities.last.entityId}');
      engine.applySnapshotPage(entities, next, json['cursor'] as String?);
      count += entities.length;
      if (json['hasMore'] != true || entities.isEmpty) break;
    }
    final held = engine.finishRebuild();
    final tail = await _pull();
    return PullResult(
      changes: count + tail.changes,
      rebuilt: true,
      heldForReview: held,
    );
  }

  List<ChangeRecord> _records(Object? list) => [
    for (final c in (list as List? ?? const []).cast<Map<String, Object?>>())
      ChangeRecord.fromJson(c.cast<String, Object?>()),
  ];

  // Remote workspaces and devices -------------------------------------------

  /// The server workspaces the signed-in user belongs to.
  Future<List<RemoteWorkspace>> listRemoteWorkspaces() async => [
    for (final w in await transport.getJsonList('/v1/workspaces'))
      RemoteWorkspace.fromJson((w! as Map).cast<String, Object?>()),
  ];

  /// Creates a server workspace owned by the signed-in user with this
  /// workspace's currency and timezone. The id is generated here, so a
  /// retry after a lost response finds the workspace instead of creating a
  /// second one.
  Future<RemoteWorkspace> createRemoteWorkspace({required String name}) async {
    final settings = _ctx.settings;
    final id = newId();
    final response = await transport.send(
      () => transport.postRequest('/v1/workspaces', {
        'id': id,
        'name': name,
        'currency': settings.currency.code,
        'timezone': settings.timezone,
      }),
      acceptStatus: (s) => s == 409,
    );
    if (response.statusCode == 409) {
      final error = SyncHttpException(
        response.statusCode,
        response.body,
        'POST /v1/workspaces',
      );
      if (error.errorCode != 'WORKSPACE_EXISTS') throw error;
      // An earlier attempt created it and its answer was lost.
      return RemoteWorkspace.fromJson(
        await transport.getJson('/v1/workspaces/$id'),
      );
    }
    return RemoteWorkspace.fromJson(SyncTransport.decodeObject(response));
  }

  /// Registers this device (the store's device id) in [workspaceId], which
  /// the user must belong to. Registering again is harmless; a revoked
  /// device answers `409 DEVICE_REVOKED`.
  Future<void> registerDevice({
    required String workspaceId,
    required String name,
    required String platform,
  }) async {
    await transport.postJson('/v1/devices', {
      'deviceId': _ctx.settings.deviceId,
      'workspaceId': workspaceId,
      'name': name,
      'platform': platform,
    });
  }

  // Bootstrap ----------------------------------------------------------------

  /// Describes what enabling sync against [remoteWorkspaceId] will do. The
  /// device ([deviceId], by default the store's) must already be registered
  /// in that workspace with [registerDevice].
  Future<SyncBootstrapPreview> previewBootstrap({
    required String remoteWorkspaceId,
    String? deviceId,
  }) => _serial(() async {
    if (_ctx.settings.syncMode == SyncMode.synced) {
      throw StateError('Sync is already enabled');
    }
    final remote = await transport.getJson(
      '/v1/sync/changes',
      query: {'cursor': '', 'limit': '1'},
      extraHeaders: {
        deviceIdHeader: deviceId ?? _ctx.settings.deviceId,
        workspaceIdHeader: remoteWorkspaceId,
      },
    );
    return SyncBootstrapPreview(
      remoteWorkspaceId: remoteWorkspaceId,
      deviceId: deviceId ?? _ctx.settings.deviceId,
      localCounts: _localCounts(),
      pendingCommands: _store.pendingCommandCount,
      remoteHasData: (remote['changes'] as List? ?? const []).isNotEmpty,
      outboxHead: _outboxHead(),
    );
  });

  Map<String, int> _localCounts() {
    int count(String sql) => _ctx.db.select(sql).first.values.first as int;
    final counts = {
      'account': count('SELECT count(*) FROM accounts WHERE deleted = 0'),
      'category': count('SELECT count(*) FROM categories WHERE deleted = 0'),
      'journal': count('SELECT count(*) FROM journals WHERE deleted = 0'),
      'asset': count('SELECT count(*) FROM assets'),
    };
    for (final r in _ctx.db.select(
      'SELECT entity_type, count(*) n FROM entities WHERE deleted = 0 '
      'GROUP BY entity_type',
    )) {
      counts[r['entity_type'] as String] = r['n'] as int;
    }
    return counts;
  }

  int _outboxHead() =>
      (_ctx.db.select('SELECT MAX(seq) FROM outbox').first.values.first
          as int?) ??
      0;

  /// Switches the workspace to synced mode as previewed. Local commands
  /// are re-addressed to the server workspace and keep their order, so the
  /// complete local history is uploaded by the next [sync].
  Future<void> enableSync(SyncBootstrapPreview preview) => _serial(() async {
    if (preview.action == BootstrapAction.mergeRefused) {
      throw WorkspaceMergeRefusedException();
    }
    if (_outboxHead() != preview.outboxHead ||
        _ctx.settings.syncMode == SyncMode.synced) {
      throw StalePreviewException();
    }
    _ctx.write(() {
      _ctx.db.execute(
        "UPDATE workspace SET workspace_id = ?, device_id = ?, sync_mode = 'synced'",
        [preview.remoteWorkspaceId, preview.deviceId],
      );
      for (final entry in _ctx.outbox.pending()) {
        final c = entry.command;
        _ctx.outbox.updateCommand(
          entry.seq,
          SyncCommand(
            commandId: c.commandId,
            workspaceId: preview.remoteWorkspaceId,
            deviceId: preview.deviceId,
            type: c.type,
            entityType: c.entityType,
            entityId: c.entityId,
            baseRevision: c.baseRevision,
            schemaVersion: c.schemaVersion,
            payload: c.payload,
          ),
        );
      }
      _ctx.setSyncValue(SyncKeys.cursor, null);
    });
    _ctx.reloadSettings();
  });
}
