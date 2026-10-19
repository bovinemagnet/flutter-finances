import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:finance_core/finance_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory implementation of `spec/sync/protocol.md` for tests.
///
/// Each command is applied atomically with its idempotency record and
/// change records. Entity revisions start at 1; `entity.upsert` keeps a
/// revision per field and merges non-conflicting fields. Cursors are
/// `c<sequence>`; [expireTombstones] purges tombstones and makes older
/// cursors answer 410 `CURSOR_EXPIRED`.
class FakeSyncServer {
  FakeSyncServer({required this.workspaceId, this.currency = Currency.aud});

  static final base = Uri.parse('https://sync.test');

  String workspaceId;
  final Currency currency;

  final Map<String, ServerEntity> entities = {};
  final List<_Change> _log = [];
  final Map<String, _Idempotency> _idempotency = {};
  int _seq = 0;
  int _horizon = 0;

  /// Receipt objects by asset id.
  final Map<String, UploadIntent> intents = {};
  final Map<String, Uint8List> objects = {};
  final Map<String, String> assetStatus = {};
  int completions = 0;

  // Fault injection --------------------------------------------------------

  /// When true every request fails as if the device were offline.
  bool offline = false;

  /// Commit the next N command batches, then lose the response.
  int dropCommandResponses = 0;

  /// Answer the next N requests matching [failPath] with HTTP 503.
  int failRequests = 0;
  String failPath = '';

  /// Snapshot page size, small to exercise paging.
  int snapshotPageSize = 500;

  /// When set, snapshot pages after this many served ones answer 503.
  int? failSnapshotAfterPages;
  int _snapshotPagesServed = 0;

  int _activePuts = 0;
  int maxConcurrentPuts = 0;
  Duration putDelay = Duration.zero;

  final List<String> requests = [];

  late final http.Client client = MockClient(_handle);

  int commandCount = 0;

  // Inspection helpers -----------------------------------------------------

  ServerEntity? entity(String type, String id) => entities['$type:$id'];

  Iterable<ServerEntity> live(String type) =>
      entities.values.where((e) => e.type == type && !e.deleted);

  /// Purges tombstones and invalidates every cursor issued so far
  /// (SYNC 06: devices older than the horizon must rebase from a snapshot).
  void expireTombstones() {
    entities.removeWhere((_, e) => e.deleted);
    final purged = _log.where((c) => !entities.containsKey(c.key)).toList();
    _log.removeWhere(purged.contains);
    _horizon = _seq;
  }

  // HTTP -------------------------------------------------------------------

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} ${request.url}');
    if (offline) throw http.ClientException('Network is unreachable');
    if (failRequests > 0 && path.contains(failPath)) {
      failRequests--;
      return _json(503, {'error': 'UNAVAILABLE'});
    }
    if (request.method == 'POST' && path == '/v1/sync/commands') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final results = [
        for (final c in (body['commands'] as List).cast<Map<String, Object?>>())
          _command(c),
      ];
      if (dropCommandResponses > 0) {
        dropCommandResponses--;
        throw TimeoutException('response lost after commit');
      }
      return _json(200, {'results': results});
    }
    if (request.method == 'GET' && path == '/v1/sync/changes') {
      return _changes(request.url.queryParameters);
    }
    if (request.method == 'GET' && path == '/v1/sync/snapshot') {
      return _snapshot(request.url.queryParameters);
    }
    if (request.method == 'POST' && path == '/v1/receipts/upload-intents') {
      return _intent(jsonDecode(request.body) as Map<String, Object?>);
    }
    if (request.method == 'PUT' && request.url.host == 'objects.test') {
      return _put(request);
    }
    final complete = RegExp(r'^/v1/receipts/([^/]+)/complete$')
        .firstMatch(path);
    if (request.method == 'POST' && complete != null) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      return _complete(complete[1]!, body['assetId'] as String);
    }
    final download = RegExp(r'^/v1/receipts/([^/]+)/assets/([^/]+)/download$')
        .firstMatch(path);
    if (request.method == 'GET' && download != null) {
      return _download(download[1]!, download[2]!);
    }
    if (request.method == 'GET' && request.url.host == 'objects.test') {
      final id = request.url.pathSegments.last;
      final bytes = objects[id];
      return bytes == null
          ? _json(404, {'error': 'NOT_FOUND'})
          : http.Response.bytes(bytes, 200);
    }
    return _json(404, {'error': 'NOT_FOUND'});
  }

  http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  // Commands ---------------------------------------------------------------

  Map<String, Object?> _command(Map<String, Object?> json) {
    commandCount++;
    final command = SyncCommand.fromJson(json);
    final hash = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              json['type'],
              json['entityType'],
              json['entityId'],
              json['payload'],
            ]),
          ),
        )
        .toString();
    final previous = _idempotency[command.commandId];
    if (previous != null) {
      if (previous.hash != hash) {
        return _fail(command, ['IDEMPOTENCY_KEY_REUSED']);
      }
      return {...previous.result, 'status': 'previously_applied'};
    }
    if (command.workspaceId != workspaceId) {
      return {'commandId': command.commandId, 'status': 'permission_denied'};
    }
    final result = switch (command.type) {
      CommandType.journalPost => _journalPost(command),
      CommandType.journalCorrect => _journalCorrect(command),
      CommandType.entityUpsert => _upsert(command),
      CommandType.entityDelete => _delete(command),
    };
    if (result['status'] == 'applied') {
      _idempotency[command.commandId] = _Idempotency(hash, result);
    }
    return result;
  }

  Map<String, Object?> _fail(SyncCommand c, List<String> errors) => {
    'commandId': c.commandId,
    'status': 'validation_failed',
    'errors': errors,
  };

  Map<String, Object?> _conflict(
    SyncCommand c,
    ServerEntity? current, [
    List<String> fields = const [],
  ]) => {
    'commandId': c.commandId,
    'status': 'conflict',
    'conflict': {
      'serverRevision': current?.revision ?? 0,
      'serverState': current == null || current.deleted ? null : current.data,
      'fields': fields,
    },
  };

  Map<String, Object?> _applied(SyncCommand c, int revision) => {
    'commandId': c.commandId,
    'status': 'applied',
    'revision': revision,
    'cursor': 'c$_seq',
  };

  void _write(
    String type,
    String id,
    Map<String, Object?> data, {
    bool deleted = false,
    Map<String, int>? fieldRevisions,
  }) {
    final key = '$type:$id';
    final previous = entities[key];
    final revision = (previous?.revision ?? 0) + 1;
    final entity = ServerEntity(
      type,
      id,
      Map.of(data),
      revision,
      deleted: deleted,
      fieldRevisions: fieldRevisions ?? previous?.fieldRevisions ?? {},
    );
    entities[key] = entity;
    _seq++;
    _log.add(_Change(_seq, key));
  }

  List<String> _validateJournal(Map<String, Object?> json) {
    final errors = <String>[];
    if (json['currency'] != null && json['currency'] != currency.code) {
      return ['CURRENCY_MISMATCH'];
    }
    final Journal journal;
    try {
      journal = journalFromJson(json, currency);
    } on Object {
      return ['MALFORMED'];
    }
    if (journal.status == JournalStatus.reversed) errors.add('INVALID_STATUS');
    errors.addAll(validatePostings(journal.postings).map((e) => e.code));
    for (final p in journal.postings) {
      final a = p.ledgerAccountId;
      final known =
          a.startsWith('system:') ||
          (entity('account', a)?.deleted == false) ||
          (entity('category', a)?.deleted == false);
      if (!known) {
        errors.add('UNKNOWN_LEDGER_ACCOUNT');
        break;
      }
    }
    return errors;
  }

  Map<String, Object?> _journalPost(SyncCommand c) {
    final json = ((c.payload['journal'] as Map?) ?? c.payload)
        .cast<String, Object?>();
    final current = entity('journal', c.entityId);
    if (current == null && c.baseRevision > 0) return _conflict(c, null);
    if (current != null) {
      if (current.deleted) return _conflict(c, current);
      final status = current.data['status'];
      if (status == 'posted' || status == 'reversed') {
        return _fail(c, ['POSTED_JOURNAL_IMMUTABLE']);
      }
      if (current.revision != c.baseRevision) return _conflict(c, current);
    }
    final errors = _validateJournal(json);
    if (errors.isNotEmpty) return _fail(c, errors);
    _write('journal', c.entityId, json);
    return _applied(c, entity('journal', c.entityId)!.revision);
  }

  Map<String, Object?> _journalCorrect(SyncCommand c) {
    final original = entity('journal', c.entityId);
    if (original == null || original.deleted) return _conflict(c, original);
    if (original.revision != c.baseRevision) return _conflict(c, original);
    if (original.data['status'] != 'posted') return _conflict(c, original);
    final reversal = (c.payload['reversal'] as Map).cast<String, Object?>();
    final replacement = (c.payload['replacement'] as Map?)
        ?.cast<String, Object?>();
    final errors = [
      ..._validateJournal(reversal),
      if (replacement != null) ..._validateJournal(replacement),
    ];
    final expected = [
      for (final p
          in (original.data['postings'] as List).cast<Map<String, Object?>>())
        '${p['account']}:${-(p['amountMinor'] as int)}',
    ];
    final actual = [
      for (final p
          in (reversal['postings'] as List).cast<Map<String, Object?>>())
        '${p['account']}:${p['amountMinor']}',
    ];
    if (reversal['reversalOf'] != c.entityId ||
        jsonEncode(expected) != jsonEncode(actual)) {
      errors.add('REVERSAL_MISMATCH');
    }
    if (errors.isNotEmpty) return _fail(c, errors);
    _write('journal', c.entityId, {...original.data, 'status': 'reversed'});
    final revision = entity('journal', c.entityId)!.revision;
    _write('journal', reversal['id'] as String, reversal);
    if (replacement != null) {
      _write('journal', replacement['id'] as String, replacement);
    }
    return {..._applied(c, revision)};
  }

  Map<String, Object?> _upsert(SyncCommand c) {
    if (c.entityType == 'journal') return _fail(c, ['USE_JOURNAL_COMMANDS']);
    final fields = (c.payload['fields'] as Map).cast<String, Object?>();
    final current = entity(c.entityType, c.entityId);
    if (current == null) {
      if (c.baseRevision != 0) return _conflict(c, null);
      _write(
        c.entityType,
        c.entityId,
        fields,
        fieldRevisions: {for (final f in fields.keys) f: 1},
      );
      return _applied(c, 1);
    }
    if (current.deleted) return _conflict(c, current);
    final conflicting = [
      for (final e in fields.entries)
        if ((current.fieldRevisions[e.key] ?? 0) > c.baseRevision &&
            jsonEncode(current.data[e.key]) != jsonEncode(e.value))
          e.key,
    ];
    if (conflicting.isNotEmpty) return _conflict(c, current, conflicting);
    final revision = current.revision + 1;
    _write(
      c.entityType,
      c.entityId,
      {...current.data, ...fields},
      fieldRevisions: {
        ...current.fieldRevisions,
        for (final e in fields.entries)
          if (jsonEncode(current.data[e.key]) != jsonEncode(e.value))
            e.key: revision,
      },
    );
    return _applied(c, revision);
  }

  Map<String, Object?> _delete(SyncCommand c) {
    final current = entity(c.entityType, c.entityId);
    if (current == null || current.deleted) return _conflict(c, current);
    if (c.entityType == 'journal' &&
        (current.data['status'] == 'posted' ||
            current.data['status'] == 'reversed')) {
      return _fail(c, ['POSTED_JOURNAL_IMMUTABLE']);
    }
    if (current.revision != c.baseRevision) return _conflict(c, current);
    _write(c.entityType, c.entityId, current.data, deleted: true);
    return _applied(c, entity(c.entityType, c.entityId)!.revision);
  }

  // Change feed and snapshot -------------------------------------------------

  Map<String, Object?> _changeJson(String key) {
    final e = entities[key]!;
    return {
      'entityType': e.type,
      'entityId': e.id,
      'revision': e.revision,
      'op': e.deleted ? 'delete' : 'upsert',
      'data': e.deleted ? {'id': e.id} : e.data,
    };
  }

  http.Response _changes(Map<String, String> query) {
    final cursor = query['cursor'] ?? '';
    final limit = int.parse(query['limit'] ?? '500');
    final from = cursor.isEmpty ? 0 : int.parse(cursor.substring(1));
    if (cursor.isNotEmpty && from < _horizon) {
      return _json(410, {'error': 'CURSOR_EXPIRED'});
    }
    // Only the latest change per entity matters; older ones are skipped.
    final pending = _log.where((c) => c.seq > from).toList();
    final page = pending.take(limit).toList();
    final latest = <String, _Change>{};
    for (final c in page) {
      latest[c.key] = c;
    }
    final next = page.isEmpty ? from : page.last.seq;
    return _json(200, {
      'changes': [
        for (final c in page)
          if (latest[c.key] == c) _changeJson(c.key),
      ],
      'cursor': 'c$next',
      'hasMore': pending.length > page.length,
    });
  }

  http.Response _snapshot(Map<String, String> query) {
    final limit = failSnapshotAfterPages;
    if (limit != null && _snapshotPagesServed >= limit) {
      return _json(503, {'error': 'UNAVAILABLE'});
    }
    _snapshotPagesServed++;
    final after = query['after'] ?? '';
    final keys =
        entities.entries
            .where((e) => !e.value.deleted)
            .map((e) => e.key)
            .where((k) => after.isEmpty || k.compareTo(after) > 0)
            .toList()
          ..sort();
    final page = keys.take(snapshotPageSize).toList();
    return _json(200, {
      'changes': [for (final k in page) _changeJson(k)],
      'after': page.isEmpty ? after : page.last,
      'hasMore': keys.length > page.length,
      'cursor': 'c$_seq',
    });
  }

  // Receipts -----------------------------------------------------------------

  http.Response _intent(Map<String, Object?> body) {
    final receiptId = body['receiptId'] as String;
    final owner = entity('receipt', receiptId);
    if (owner == null || owner.deleted) {
      return _json(404, {'error': 'RECEIPT_NOT_FOUND'});
    }
    final assetId = body['assetId'] as String;
    intents[assetId] = UploadIntent(
      receiptId,
      body['contentType'] as String,
      body['sizeBytes'] as int,
      body['sha256'] as String,
    );
    return _json(200, {
      'uploadUrl': 'https://objects.test/$workspaceId/$assetId',
      'headers': {'content-type': body['contentType']},
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 15))
          .toUtc()
          .toIso8601String(),
    });
  }

  Future<http.Response> _put(http.Request request) async {
    _activePuts++;
    if (_activePuts > maxConcurrentPuts) maxConcurrentPuts = _activePuts;
    try {
      await Future<void>.delayed(putDelay);
      objects[request.url.pathSegments.last] = request.bodyBytes;
      return http.Response('', 200);
    } finally {
      _activePuts--;
    }
  }

  http.Response _complete(String receiptId, String assetId) {
    final intent = intents[assetId];
    if (intent == null || intent.receiptId != receiptId) {
      return _json(404, {'error': 'UNKNOWN_ASSET'});
    }
    if (assetStatus[assetId] == 'available') {
      return _json(200, {'status': 'available'});
    }
    final bytes = objects[assetId];
    if (bytes == null) return _json(409, {'error': 'OBJECT_MISSING'});
    if (bytes.length != intent.size ||
        sha256.convert(bytes).toString() != intent.sha256) {
      return _json(422, {'error': 'CHECKSUM_MISMATCH'});
    }
    final magicOk = switch (intent.contentType) {
      'image/jpeg' => bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8,
      'image/png' => bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50,
      'application/pdf' =>
        utf8.decode(bytes.take(4).toList(), allowMalformed: true) == '%PDF',
      _ => false,
    };
    if (!magicOk) return _json(422, {'error': 'CONTENT_TYPE_MISMATCH'});
    completions++;
    // The scan job is immediate here: quarantined, then available.
    assetStatus[assetId] = 'available';
    return _json(200, {'status': 'quarantined'});
  }

  http.Response _download(String receiptId, String assetId) {
    final intent = intents[assetId];
    if (intent == null || intent.receiptId != receiptId) {
      return _json(404, {'error': 'NOT_FOUND'});
    }
    if (assetStatus[assetId] != 'available') {
      return _json(409, {'error': 'ASSET_NOT_AVAILABLE'});
    }
    return _json(200, {
      'downloadUrl': 'https://objects.test/$workspaceId/$assetId',
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
    });
  }
}

class ServerEntity {
  ServerEntity(
    this.type,
    this.id,
    this.data,
    this.revision, {
    this.deleted = false,
    this.fieldRevisions = const {},
  });

  final String type;
  final String id;
  final Map<String, Object?> data;
  final int revision;
  final bool deleted;
  final Map<String, int> fieldRevisions;
}

class _Change {
  _Change(this.seq, this.key);
  final int seq;
  final String key;
}

class _Idempotency {
  _Idempotency(this.hash, this.result);
  final String hash;
  final Map<String, Object?> result;
}

class UploadIntent {
  UploadIntent(this.receiptId, this.contentType, this.size, this.sha256);
  final String receiptId;
  final String contentType;
  final int size;
  final String sha256;
}
