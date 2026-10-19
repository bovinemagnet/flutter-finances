import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:finance_core/finance_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory implementation of `spec/sync/protocol.md` for tests,
/// following the "Server behaviour" section and the real server's error
/// codes.
///
/// Callers are keyed by their bearer token, which this fake treats as the
/// OIDC subject. Workspaces and devices are registered as on the real
/// server; the `/v1/sync/*` endpoints need a registered `X-Device-Id`, and
/// receipt endpoints take `X-Workspace-Id` or the device's workspace.
///
/// The fake holds the synchronised data of one workspace, [workspaceId];
/// other workspaces exist for listing, registration and membership checks.
/// Each command is applied atomically with its idempotency record and
/// change records. Entity identifiers are unique across entity types, as on
/// the server. Cursors are `c<sequence>`; [expireTombstones] purges
/// tombstones and makes older cursors answer 410 `CURSOR_EXPIRED`.
class FakeSyncServer {
  FakeSyncServer({
    required this.workspaceId,
    this.currency = Currency.aud,
    String owner = defaultUser,
  }) {
    workspaces[workspaceId] = FakeWorkspace(
      id: workspaceId,
      name: 'Cloud',
      currency: currency.code,
      timezone: 'Australia/Sydney',
      members: {owner: 'owner'},
    );
  }

  /// The subject (and bearer token) of the default user.
  static const defaultUser = 'user';

  static final base = Uri.parse('https://sync.test');

  /// The workspace whose synchronised data this fake holds.
  String workspaceId;
  final Currency currency;

  final Map<String, FakeWorkspace> workspaces = {};
  final Map<String, FakeDevice> devices = {};

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

  /// Handle the next N requests matching [dropPath], then lose the answer.
  int dropResponses = 0;
  String dropPath = '';

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

  /// Every request as `METHOD url`.
  final List<String> requests = [];

  /// Every request received, with its headers.
  final List<http.Request> received = [];

  late final http.Client client = MockClient(_handle);

  int commandCount = 0;

  static const maxPageSize = 500;
  static const maxCommandsPerBatch = 500;
  static const maxSizeBytes = 20 * 1024 * 1024;
  static const maxPagesPerReceipt = 10;
  static const _systemAccounts = {
    'system:opening-equity',
    'system:balance-adjustments',
    'system:transfer-clearing',
    'system:reimbursement-receivable',
  };
  static const _acceptedContentTypes = {
    'image/jpeg',
    'image/png',
    'image/heic',
    'image/heif',
    'application/pdf',
  };

  // Inspection helpers -----------------------------------------------------

  ServerEntity? entity(String type, String id) {
    final e = entities[id];
    return e != null && e.type == type ? e : null;
  }

  Iterable<ServerEntity> live(String type) =>
      entities.values.where((e) => e.type == type && !e.deleted);

  /// Purges tombstones and invalidates every cursor issued so far
  /// (SYNC 06: devices older than the horizon must rebase from a snapshot).
  void expireTombstones() {
    entities.removeWhere((_, e) => e.deleted);
    final purged = _log.where((c) => !entities.containsKey(c.id)).toList();
    _log.removeWhere(purged.contains);
    _horizon = _seq;
  }

  /// Revokes a device for good, as `DELETE /v1/devices/{id}` does.
  void revokeDevice(String deviceId) => devices[deviceId]!.revoked = true;

  // HTTP -------------------------------------------------------------------

  Future<http.Response> _handle(http.Request request) async {
    requests.add('${request.method} ${request.url}');
    received.add(request);
    if (offline) throw http.ClientException('Network is unreachable');
    final path = request.url.path;
    if (failRequests > 0 && path.contains(failPath)) {
      failRequests--;
      return _json(503, _error('UNAVAILABLE'));
    }
    if (request.url.host == 'objects.test') return _object(request);
    http.Response response;
    try {
      response = await _api(request);
    } on _HttpError catch (e) {
      response = _json(e.status, _error(e.code));
    }
    if (dropResponses > 0 && path.contains(dropPath)) {
      dropResponses--;
      throw TimeoutException('response lost after handling');
    }
    return response;
  }

  Future<http.Response> _api(http.Request request) async {
    final path = request.url.path;
    final method = request.method;
    final user = _user(request);
    if (path == '/v1/workspaces') {
      if (method == 'POST') return _createWorkspace(user, _body(request));
      if (method == 'GET') {
        return _json(200, [
          for (final w in workspaces.values)
            if (w.members.containsKey(user)) w.toJson(user),
        ]);
      }
    }
    final workspace = RegExp(r'^/v1/workspaces/([^/]+)$').firstMatch(path);
    if (workspace != null && method == 'GET') {
      final w = _member(user, workspace[1]!);
      return _json(200, {
        ...w.toJson(user),
        'schemaVersion': 1,
        'tombstoneHorizonDays': 90,
        'maxCommandsPerBatch': maxCommandsPerBatch,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
      });
    }
    if (path == '/v1/devices' && method == 'POST') {
      return _registerDevice(user, _body(request));
    }
    final device = RegExp(r'^/v1/devices/([^/]+)$').firstMatch(path);
    if (device != null && method == 'DELETE') {
      final d = devices[device[1]];
      if (d == null ||
          (d.user != user &&
              workspaces[d.workspaceId]?.members[user] != 'owner')) {
        throw _HttpError(404, 'DEVICE_NOT_FOUND');
      }
      d.revoked = true;
      return http.Response('', 204);
    }
    if (path.startsWith('/v1/sync/')) {
      final caller = _requireDevice(user, request);
      if (method == 'POST' && path == '/v1/sync/commands') {
        return _commands(caller, _body(request));
      }
      if (method == 'GET' && path == '/v1/sync/changes') {
        return _changes(request.url.queryParameters);
      }
      if (method == 'GET' && path == '/v1/sync/snapshot') {
        return _snapshot(request.url.queryParameters);
      }
    }
    if (path.startsWith('/v1/receipts/')) {
      final ws = _requireMember(user, request);
      if (method == 'POST' && path == '/v1/receipts/upload-intents') {
        return _intent(ws, _body(request));
      }
      final complete = RegExp(r'^/v1/receipts/([^/]+)/complete$')
          .firstMatch(path);
      if (method == 'POST' && complete != null) {
        return _complete(ws, complete[1]!, _body(request)['assetId'] as String);
      }
      final download = RegExp(r'^/v1/receipts/([^/]+)/assets/([^/]+)/download$')
          .firstMatch(path);
      if (method == 'GET' && download != null) {
        return _download(ws, download[1]!, download[2]!);
      }
    }
    throw _HttpError(404, 'NOT_FOUND');
  }

  Map<String, Object?> _body(http.Request request) =>
      (jsonDecode(request.body) as Map).cast<String, Object?>();

  http.Response _json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  Map<String, Object?> _error(String code) => {
    'error': code,
    'message': code,
    'correlationId': 'fake',
  };

  // Callers, workspaces and devices -------------------------------------

  String _user(http.Request request) {
    final auth = request.headers['authorization'] ?? '';
    if (!auth.startsWith('Bearer ') || auth.length <= 7) {
      throw _HttpError(401, 'UNAUTHENTICATED');
    }
    return auth.substring(7);
  }

  FakeWorkspace _member(String user, String workspaceId) {
    final w = workspaces[workspaceId];
    if (w == null || !w.members.containsKey(user)) {
      throw _HttpError(404, 'WORKSPACE_NOT_FOUND');
    }
    return w;
  }

  http.Response _createWorkspace(String user, Map<String, Object?> body) {
    final id = body['id'] as String? ?? newId();
    final name = body['name'] as String?;
    final currency = body['currency'] as String?;
    final timezone = body['timezone'] as String?;
    if (name == null || name.trim().isEmpty) {
      throw _HttpError(400, 'INVALID_REQUEST');
    }
    if (currency == null || !RegExp(r'^[A-Za-z]{3}$').hasMatch(currency)) {
      throw _HttpError(400, 'INVALID_CURRENCY');
    }
    if (timezone == null || !timezone.contains('/')) {
      throw _HttpError(400, 'INVALID_TIMEZONE');
    }
    if (workspaces.containsKey(id)) throw _HttpError(409, 'WORKSPACE_EXISTS');
    final w = workspaces[id] = FakeWorkspace(
      id: id,
      name: name.trim(),
      currency: currency.toUpperCase(),
      timezone: timezone,
      members: {user: 'owner'},
    );
    return _json(201, w.toJson(user));
  }

  http.Response _registerDevice(String user, Map<String, Object?> body) {
    final deviceId = body['deviceId'] as String?;
    final workspaceId = body['workspaceId'] as String?;
    final name = body['name'] as String?;
    final platform = body['platform'] as String?;
    if (deviceId == null ||
        workspaceId == null ||
        (name ?? '').trim().isEmpty ||
        (platform ?? '').trim().isEmpty) {
      throw _HttpError(400, 'INVALID_REQUEST');
    }
    _member(user, workspaceId);
    final existing = devices[deviceId];
    if (existing != null) {
      if (existing.user != user || existing.workspaceId != workspaceId) {
        throw _HttpError(409, 'DEVICE_EXISTS');
      }
      if (existing.revoked) throw _HttpError(409, 'DEVICE_REVOKED');
      return _json(200, existing.toJson(user));
    }
    final d = devices[deviceId] = FakeDevice(
      id: deviceId,
      workspaceId: workspaceId,
      user: user,
      name: name!.trim(),
      platform: platform!.trim(),
    );
    return _json(201, d.toJson(user));
  }

  /// `X-Device-Id` must be a registered, unrevoked device of the caller in
  /// the `X-Workspace-Id` workspace when that header is sent.
  FakeDevice _requireDevice(String user, http.Request request) {
    final deviceId = request.headers['x-device-id'];
    if (deviceId == null || deviceId.isEmpty) {
      throw _HttpError(400, 'DEVICE_REQUIRED');
    }
    final device = devices[deviceId];
    if (device == null || device.user != user) {
      throw _HttpError(403, 'DEVICE_NOT_AUTHORISED');
    }
    if (device.revoked) throw _HttpError(403, 'DEVICE_REVOKED');
    final header = request.headers['x-workspace-id'];
    if (header != null && header.isNotEmpty && header != device.workspaceId) {
      throw _HttpError(403, 'DEVICE_NOT_AUTHORISED');
    }
    _member(user, device.workspaceId);
    return device;
  }

  /// The workspace of `X-Workspace-Id`, or of the caller's `X-Device-Id`.
  FakeWorkspace _requireMember(String user, http.Request request) {
    var workspaceId = request.headers['x-workspace-id'];
    if (workspaceId == null || workspaceId.isEmpty) {
      final device = devices[request.headers['x-device-id']];
      if (device != null && device.user == user && !device.revoked) {
        workspaceId = device.workspaceId;
      }
    }
    if (workspaceId == null || workspaceId.isEmpty) {
      throw _HttpError(400, 'WORKSPACE_REQUIRED');
    }
    return _member(user, workspaceId);
  }

  // Commands ---------------------------------------------------------------

  http.Response _commands(FakeDevice device, Map<String, Object?> body) {
    final commands = body['commands'];
    if (commands is! List) throw _HttpError(400, 'INVALID_REQUEST');
    if (commands.length > maxCommandsPerBatch) {
      throw _HttpError(400, 'TOO_MANY_COMMANDS');
    }
    final results = [
      for (final c in commands.cast<Map<String, Object?>>())
        _command(device, c),
    ];
    if (dropCommandResponses > 0) {
      dropCommandResponses--;
      throw TimeoutException('response lost after commit');
    }
    return _json(200, {'results': results});
  }

  static const _commandTypes = {
    'journal.post',
    'journal.correct',
    'entity.upsert',
    'entity.delete',
  };

  Map<String, Object?> _command(FakeDevice device, Map<String, Object?> json) {
    commandCount++;
    final rawId = json['commandId'] as String?;
    final base = json['baseRevision'];
    if (rawId == null ||
        json['entityId'] is! String ||
        !_commandTypes.contains(json['type']) ||
        json['entityType'] is! String ||
        base is! int ||
        base < 0 ||
        json['schemaVersion'] is! int ||
        (json['payload'] != null && json['payload'] is! Map)) {
      return _rejected(rawId, 'validation_failed', ['INVALID_COMMAND']);
    }
    if (json['workspaceId'] != device.workspaceId ||
        json['workspaceId'] != workspaceId ||
        json['deviceId'] != device.id) {
      return _rejected(rawId, 'permission_denied', ['NOT_PERMITTED']);
    }
    final command = SyncCommand.fromJson({
      ...json,
      'payload': json['payload'] ?? <String, Object?>{},
    });
    final hash = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              command.type.wire,
              command.entityType,
              command.entityId,
              command.payload,
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
    final result = command.schemaVersion != 1
        ? _fail(command, ['UNSUPPORTED_SCHEMA_VERSION'])
        : switch (command.type) {
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

  Map<String, Object?> _rejected(
    String? commandId,
    String status,
    List<String> errors,
  ) => {'commandId': commandId, 'status': status, 'errors': errors};

  Map<String, Object?> _fail(SyncCommand c, List<String> errors) =>
      _rejected(c.commandId, 'validation_failed', errors);

  Map<String, Object?> _conflict(
    SyncCommand c,
    ServerEntity? current, {
    List<String> fields = const [],
    List<String> errors = const [],
  }) => {
    'commandId': c.commandId,
    'status': 'conflict',
    'errors': errors,
    'conflict': {
      'serverRevision': current?.revision ?? 0,
      'serverState': current == null || current.deleted ? null : current.data,
      'fields': fields,
    },
  };

  Map<String, Object?> _notFound(SyncCommand c) =>
      _conflict(c, null, errors: ['ENTITY_NOT_FOUND']);

  Map<String, Object?> _deleted(SyncCommand c, ServerEntity current) =>
      _conflict(c, current, errors: ['ENTITY_DELETED']);

  /// A stale base revision: the fields changed on the server since.
  Map<String, Object?> _stale(SyncCommand c, ServerEntity current) => _conflict(
    c,
    current,
    fields: [
      for (final e in current.fieldRevisions.entries)
        if (e.value > c.baseRevision) e.key,
    ]..sort(),
  );

  Map<String, Object?> _applied(SyncCommand c, int revision) => {
    'commandId': c.commandId,
    'status': 'applied',
    'revision': revision,
    'cursor': 'c$_seq',
    'errors': const <String>[],
  };

  void _write(
    String type,
    String id,
    Map<String, Object?> data, {
    bool deleted = false,
    Map<String, int>? fieldRevisions,
  }) {
    final previous = entities[id];
    final revision = (previous?.revision ?? 0) + 1;
    entities[id] = ServerEntity(
      type,
      id,
      Map.of(data),
      revision,
      deleted: deleted,
      fieldRevisions:
          fieldRevisions ??
          {
            ...?previous?.fieldRevisions,
            for (final e in data.entries)
              if (previous == null ||
                  jsonEncode(previous.data[e.key]) != jsonEncode(e.value))
                e.key: revision,
          },
    );
    _seq++;
    _log.add(_Change(_seq, id));
  }

  /// Parses a journal; null when malformed (`INVALID_JOURNAL`).
  ({Journal journal, bool currencyMismatch})? _parse(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, Object?>();
    final code = map['currency'];
    if (code is! String) return null;
    try {
      final journal = journalFromJson({
        ...map,
        'currency': currency.code,
      }, currency);
      return (journal: journal, currencyMismatch: code != currency.code);
    } on Object {
      return null;
    }
  }

  List<String> _validateJournal(
    ({Journal journal, bool currencyMismatch}) parsed,
  ) {
    final journal = parsed.journal;
    final errors = <String>{
      if (parsed.currencyMismatch) 'CURRENCY_MISMATCH',
      ...validatePostings(journal.postings).map((e) => e.code),
    };
    for (final p in journal.postings) {
      final a = p.ledgerAccountId;
      final known = a.startsWith('system:')
          ? _systemAccounts.contains(a)
          : (entity('account', a)?.deleted == false) ||
                (entity('category', a)?.deleted == false);
      if (!known) errors.add('UNKNOWN_LEDGER_ACCOUNT');
    }
    if (journal.status == JournalStatus.reversed) errors.add('INVALID_STATUS');
    return errors.toList();
  }

  static bool _inPostedLedger(ServerEntity e) =>
      e.data['status'] == 'posted' || e.data['status'] == 'reversed';

  Map<String, Object?> _journalPost(SyncCommand c) {
    if (c.entityType != 'journal') return _fail(c, ['INVALID_ENTITY_TYPE']);
    final json = c.payload['journal'];
    final parsed = _parse(json);
    if (parsed == null) return _fail(c, ['INVALID_JOURNAL']);
    if (parsed.journal.id != c.entityId) {
      return _fail(c, ['ENTITY_ID_MISMATCH']);
    }
    final current = entities[c.entityId];
    if (current != null) {
      if (current.deleted) return _deleted(c, current);
      if (current.type != 'journal') return _fail(c, ['ENTITY_TYPE_MISMATCH']);
      if (_inPostedLedger(current)) {
        return _fail(c, ['POSTED_JOURNAL_IMMUTABLE']);
      }
      if (current.revision != c.baseRevision) return _stale(c, current);
    } else if (c.baseRevision != 0) {
      return _notFound(c);
    }
    final errors = [
      ..._validateJournal(parsed),
      if (parsed.journal.type == TransactionType.reversal) 'INVALID_TYPE',
    ];
    if (errors.isNotEmpty) return _fail(c, errors);
    _write('journal', c.entityId, (json! as Map).cast<String, Object?>());
    return _applied(c, entities[c.entityId]!.revision);
  }

  Map<String, Object?> _journalCorrect(SyncCommand c) {
    if (c.entityType != 'journal') return _fail(c, ['INVALID_ENTITY_TYPE']);
    final payload = c.payload;
    if (payload['originalId'] is! String || payload['reversal'] is! Map) {
      return _fail(c, ['INVALID_JOURNAL']);
    }
    if (payload['originalId'] != c.entityId) {
      return _fail(c, ['ENTITY_ID_MISMATCH']);
    }
    final current = entities[c.entityId];
    if (current == null) return _notFound(c);
    if (current.deleted) return _deleted(c, current);
    if (current.type != 'journal') return _fail(c, ['ENTITY_TYPE_MISMATCH']);
    if (current.revision != c.baseRevision) return _stale(c, current);
    if (current.data['status'] == 'reversed') return _stale(c, current);
    if (current.data['status'] != 'posted') return _fail(c, ['INVALID_STATUS']);

    final original = _parse(current.data)!.journal;
    final reversalJson = (payload['reversal'] as Map).cast<String, Object?>();
    final replacementJson = payload['replacement'];
    final reversalParsed = _parse(reversalJson);
    final replacementParsed = replacementJson == null
        ? null
        : _parse(replacementJson);
    if (reversalParsed == null ||
        (replacementJson != null && replacementParsed == null)) {
      return _fail(c, ['INVALID_JOURNAL']);
    }
    final reversal = reversalParsed.journal;
    final errors = <String>{..._validateJournal(reversalParsed)};
    if (reversal.type != TransactionType.reversal ||
        reversal.status != JournalStatus.posted ||
        !_isExactReversal(original, reversal)) {
      errors.add('REVERSAL_MISMATCH');
    }
    final newIds = {reversal.id};
    if (replacementParsed != null) {
      final replacement = replacementParsed.journal;
      errors.addAll(_validateJournal(replacementParsed));
      if (replacement.type == TransactionType.reversal) {
        errors.add('INVALID_TYPE');
      }
      if (replacement.replaces != original.id) {
        errors.add('REPLACEMENT_MISMATCH');
      }
      if (!newIds.add(replacement.id)) errors.add('DUPLICATE_ENTITY');
    }
    for (final id in newIds) {
      if (id == original.id || entities.containsKey(id)) {
        errors.add('DUPLICATE_ENTITY');
      }
    }
    if (errors.isNotEmpty) return _fail(c, errors.toList());
    _write('journal', c.entityId, {...current.data, 'status': 'reversed'});
    final revision = entities[c.entityId]!.revision;
    _write('journal', reversal.id, reversalJson);
    if (replacementParsed != null) {
      _write(
        'journal',
        replacementParsed.journal.id,
        (replacementJson! as Map).cast<String, Object?>(),
      );
    }
    return _applied(c, revision);
  }

  static bool _isExactReversal(Journal original, Journal reversal) {
    if (reversal.reversalOf != original.id ||
        reversal.effectiveDate != original.effectiveDate ||
        reversal.postings.length != original.postings.length) {
      return false;
    }
    Map<String, int> net(Journal j, int sign) {
      final totals = <String, int>{};
      for (final p in j.postings) {
        totals.update(
          p.ledgerAccountId,
          (v) => v + sign * p.amount.minor,
          ifAbsent: () => sign * p.amount.minor,
        );
      }
      return totals;
    }

    return jsonEncode(_sorted(net(original, 1))) ==
        jsonEncode(_sorted(net(reversal, -1)));
  }

  static Map<String, int> _sorted(Map<String, int> m) => {
    for (final k in m.keys.toList()..sort()) k: m[k]!,
  };

  /// Field rules for accounts and categories; other types are opaque.
  static String? _checkFields(
    String type,
    Map<String, Object?> fields,
    Map<String, Object?>? existing,
  ) {
    const required = {
      'account': ['name', 'type'],
      'category': ['name', 'kind'],
    };
    const immutable = {'account': 'type', 'category': 'kind'};
    final names = required[type];
    if (names == null) return null;
    if (existing == null && names.any((f) => fields[f] == null)) {
      return 'MISSING_FIELD';
    }
    for (final e in fields.entries) {
      final v = e.value;
      final valid = switch (e.key) {
        'name' => v is String && v.trim().isNotEmpty && v.length <= 200,
        'dataSource' => v is String && v.trim().isNotEmpty,
        'type' =>
          type == 'account' &&
              v is String &&
              AccountType.values.any((t) => t.name == v),
        'kind' =>
          type == 'category' &&
              v is String &&
              CategoryKind.values.any((k) => k.name == v),
        'includeInBudget' ||
        'includeInForecast' ||
        'includeInNetWorth' ||
        'archived' => v is bool,
        'lastReconciledOn' =>
          v == null ||
              (v is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)),
        'parentId' => v == null || v is String,
        _ => true,
      };
      if (!valid) return 'INVALID_FIELD';
    }
    final key = immutable[type]!;
    if (existing != null &&
        fields.containsKey(key) &&
        jsonEncode(existing[key]) != jsonEncode(fields[key])) {
      return 'IMMUTABLE_FIELD';
    }
    return null;
  }

  Map<String, Object?> _upsert(SyncCommand c) {
    final rawFields = c.payload['fields'];
    if (rawFields is! Map) return _fail(c, ['INVALID_COMMAND']);
    final fields = Map<String, Object?>.of(rawFields.cast<String, Object?>());
    final id = fields.remove('id');
    if (id != null && id != c.entityId) return _fail(c, ['ENTITY_ID_MISMATCH']);
    if (c.entityType == 'journal') return _fail(c, ['USE_JOURNAL_COMMANDS']);
    final current = entities[c.entityId];
    if (current == null) {
      if (c.baseRevision != 0) return _notFound(c);
      final error = _checkFields(c.entityType, fields, null);
      if (error != null) return _fail(c, [error]);
      _write(c.entityType, c.entityId, {'id': c.entityId, ...fields});
      return _applied(c, 1);
    }
    if (current.deleted) return _deleted(c, current);
    if (current.type != c.entityType) {
      return _fail(c, ['ENTITY_TYPE_MISMATCH']);
    }
    final conflicting = [
      for (final e in fields.entries)
        if ((current.fieldRevisions[e.key] ?? 0) > c.baseRevision &&
            jsonEncode(current.data[e.key]) != jsonEncode(e.value))
          e.key,
    ]..sort();
    if (conflicting.isNotEmpty) {
      return _conflict(c, current, fields: conflicting);
    }
    final error = _checkFields(c.entityType, fields, current.data);
    if (error != null) return _fail(c, [error]);
    final changed = fields.entries.any(
      (e) => jsonEncode(current.data[e.key]) != jsonEncode(e.value),
    );
    // An unchanged entity keeps its revision and gets no change record.
    if (!changed) return _applied(c, current.revision);
    _write(c.entityType, c.entityId, {...current.data, ...fields});
    return _applied(c, entities[c.entityId]!.revision);
  }

  Map<String, Object?> _delete(SyncCommand c) {
    final current = entities[c.entityId];
    if (current == null) return _notFound(c);
    if (current.deleted) return _deleted(c, current);
    if (current.type != c.entityType) {
      return _fail(c, ['ENTITY_TYPE_MISMATCH']);
    }
    if (c.entityType == 'journal' && _inPostedLedger(current)) {
      return _fail(c, ['POSTED_JOURNAL_IMMUTABLE']);
    }
    if (current.revision != c.baseRevision) return _stale(c, current);
    if ((c.entityType == 'account' || c.entityType == 'category') &&
        _isReferenced(c.entityId)) {
      return _fail(c, ['ENTITY_IN_USE']);
    }
    _write(
      c.entityType,
      c.entityId,
      current.data,
      deleted: true,
      fieldRevisions: current.fieldRevisions,
    );
    return _applied(c, entities[c.entityId]!.revision);
  }

  bool _isReferenced(String ledgerAccountId) => live('journal').any(
    (j) => (j.data['postings'] as List).any(
      (p) => (p as Map)['account'] == ledgerAccountId,
    ),
  );

  // Change feed and snapshot -------------------------------------------------

  Map<String, Object?> _changeJson(String id) {
    final e = entities[id]!;
    return {
      'entityType': e.type,
      'entityId': e.id,
      'revision': e.revision,
      'op': e.deleted ? 'delete' : 'upsert',
      'data': e.deleted ? {'id': e.id} : e.data,
    };
  }

  int _limit(Map<String, String> query) {
    final limit = int.tryParse(query['limit'] ?? '') ?? maxPageSize;
    return limit.clamp(1, maxPageSize);
  }

  http.Response _changes(Map<String, String> query) {
    final cursor = query['cursor'] ?? '';
    final limit = _limit(query);
    final from = cursor.isEmpty ? 0 : int.parse(cursor.substring(1));
    if (cursor.isNotEmpty && from < _horizon) {
      throw _HttpError(410, 'CURSOR_EXPIRED');
    }
    // Only the latest change per entity matters; older ones are skipped.
    final pending = _log.where((c) => c.seq > from).toList();
    final page = pending.take(limit).toList();
    final latest = <String, _Change>{};
    for (final c in page) {
      latest[c.id] = c;
    }
    final next = page.isEmpty ? from : page.last.seq;
    return _json(200, {
      'changes': [
        for (final c in page)
          if (latest[c.id] == c) _changeJson(c.id),
      ],
      'cursor': 'c$next',
      'hasMore': pending.length > page.length,
    });
  }

  http.Response _snapshot(Map<String, String> query) {
    final limit = failSnapshotAfterPages;
    if (limit != null && _snapshotPagesServed >= limit) {
      throw _HttpError(503, 'UNAVAILABLE');
    }
    _snapshotPagesServed++;
    final after = query['after'] ?? '';
    String key(ServerEntity e) => '${e.type}/${e.id}';
    final keys =
        entities.values
            .where((e) => !e.deleted)
            .where((e) => after.isEmpty || key(e).compareTo(after) > 0)
            .toList()
          ..sort((x, y) => key(x).compareTo(key(y)));
    final page = keys.take(snapshotPageSize.clamp(1, _limit(query))).toList();
    return _json(200, {
      'changes': [for (final e in page) _changeJson(e.id)],
      'after': page.isEmpty ? after : key(page.last),
      'hasMore': keys.length > page.length,
      'cursor': 'c$_seq',
    });
  }

  // Receipts -----------------------------------------------------------------

  http.Response _intent(FakeWorkspace ws, Map<String, Object?> body) {
    final kind = body['kind'];
    final contentType = body['contentType'];
    final size = body['sizeBytes'];
    final checksum = body['sha256'];
    if (kind != 'source' && kind != 'derivative') {
      throw _HttpError(400, 'INVALID_KIND');
    }
    if (!_acceptedContentTypes.contains(contentType)) {
      throw _HttpError(400, 'UNSUPPORTED_CONTENT_TYPE');
    }
    if (size is! int || size <= 0) throw _HttpError(400, 'INVALID_REQUEST');
    if (size > maxSizeBytes) throw _HttpError(400, 'TOO_LARGE');
    if (checksum is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      throw _HttpError(400, 'INVALID_CHECKSUM');
    }
    final receiptId = body['receiptId'] as String;
    final owner = entity('receipt', receiptId);
    if (ws.id != workspaceId || owner == null || owner.deleted) {
      throw _HttpError(404, 'RECEIPT_NOT_FOUND');
    }
    final assetId = body['assetId'] as String;
    final existing = intents[assetId];
    if (existing != null) {
      if (existing.receiptId != receiptId) {
        throw _HttpError(404, 'RECEIPT_NOT_FOUND');
      }
      if (assetStatus.containsKey(assetId) && existing.sha256 != checksum) {
        throw _HttpError(409, 'ASSET_ALREADY_COMPLETE');
      }
    }
    if (!assetStatus.containsKey(assetId)) {
      intents[assetId] = UploadIntent(
        receiptId,
        contentType as String,
        size,
        checksum,
        kind: kind as String,
      );
    }
    return _json(200, {
      'uploadUrl': 'https://objects.test/$workspaceId/uploads/$assetId',
      'headers': {'content-type': contentType},
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 15))
          .toUtc()
          .toIso8601String(),
    });
  }

  /// Presigned object storage URLs carry their own signature; API
  /// credentials and scope headers must never be sent to them.
  Future<http.Response> _object(http.Request request) async {
    for (final h in ['authorization', 'x-device-id', 'x-workspace-id']) {
      if (request.headers.containsKey(h)) {
        return http.Response('API header $h sent to object storage', 400);
      }
    }
    final id = request.url.pathSegments.last;
    if (request.method == 'PUT') {
      _activePuts++;
      if (_activePuts > maxConcurrentPuts) maxConcurrentPuts = _activePuts;
      try {
        await Future<void>.delayed(putDelay);
        objects[id] = request.bodyBytes;
        return http.Response('', 200);
      } finally {
        _activePuts--;
      }
    }
    if (request.method == 'GET') {
      final bytes = objects[id];
      return bytes == null
          ? http.Response('NoSuchKey', 404)
          : http.Response.bytes(bytes, 200);
    }
    return http.Response('', 405);
  }

  http.Response _complete(FakeWorkspace ws, String receiptId, String assetId) {
    final intent = intents[assetId];
    if (ws.id != workspaceId ||
        intent == null ||
        intent.receiptId != receiptId) {
      throw _HttpError(404, 'UNKNOWN_ASSET');
    }
    if (assetStatus[assetId] case final status?) {
      return _json(200, {'status': status});
    }
    final bytes = objects[assetId];
    if (bytes == null) throw _HttpError(409, 'OBJECT_MISSING');
    if (bytes.length != intent.size ||
        sha256.convert(bytes).toString() != intent.sha256) {
      objects.remove(assetId);
      throw _HttpError(422, 'CHECKSUM_MISMATCH');
    }
    final magicOk = switch (intent.contentType) {
      'image/jpeg' => bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8,
      'image/png' => bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50,
      'application/pdf' =>
        utf8.decode(bytes.take(4).toList(), allowMalformed: true) == '%PDF',
      _ => false,
    };
    if (!magicOk) {
      objects.remove(assetId);
      throw _HttpError(422, 'CONTENT_TYPE_MISMATCH');
    }
    final pages = intent.contentType == 'application/pdf'
        ? inspectPdf(bytes).pageCount ?? 1
        : 1;
    if (intent.kind == 'source') {
      final others = intents.entries
          .where(
            (e) =>
                e.key != assetId &&
                e.value.receiptId == receiptId &&
                e.value.kind == 'source' &&
                assetStatus.containsKey(e.key),
          )
          .fold<int>(0, (n, e) => n + (e.value.pages ?? 1));
      if (others + pages > maxPagesPerReceipt) {
        objects.remove(assetId);
        throw _HttpError(422, 'TOO_MANY_PAGES');
      }
    }
    intent.pages = pages;
    completions++;
    // The scan job is immediate here: quarantined, then available.
    assetStatus[assetId] = 'available';
    return _json(200, {'status': 'quarantined'});
  }

  http.Response _download(FakeWorkspace ws, String receiptId, String assetId) {
    final intent = intents[assetId];
    if (ws.id != workspaceId ||
        intent == null ||
        intent.receiptId != receiptId) {
      throw _HttpError(404, 'NOT_FOUND');
    }
    if (assetStatus[assetId] != 'available') {
      throw _HttpError(409, 'ASSET_NOT_AVAILABLE');
    }
    return _json(200, {
      'downloadUrl': 'https://objects.test/$workspaceId/receipts/$assetId',
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
    });
  }
}

class _HttpError implements Exception {
  _HttpError(this.status, this.code);
  final int status;
  final String code;
}

class FakeWorkspace {
  FakeWorkspace({
    required this.id,
    required this.name,
    required this.currency,
    required this.timezone,
    required this.members,
  });

  final String id;
  final String name;
  final String currency;
  final String timezone;

  /// Role by user.
  final Map<String, String> members;

  Map<String, Object?> toJson(String user) => {
    'id': id,
    'name': name,
    'currency': currency,
    'currencyExponent': 2,
    'timezone': timezone,
    'role': members[user],
  };
}

class FakeDevice {
  FakeDevice({
    required this.id,
    required this.workspaceId,
    required this.user,
    required this.name,
    required this.platform,
  });

  final String id;
  final String workspaceId;
  final String user;
  final String name;
  final String platform;
  bool revoked = false;

  Map<String, Object?> toJson(String caller) => {
    'deviceId': id,
    'workspaceId': workspaceId,
    'name': name,
    'platform': platform,
    'revoked': revoked,
    'mine': user == caller,
  };
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
  _Change(this.seq, this.id);
  final int seq;
  final String id;
}

class _Idempotency {
  _Idempotency(this.hash, this.result);
  final String hash;
  final Map<String, Object?> result;
}

class UploadIntent {
  UploadIntent(
    this.receiptId,
    this.contentType,
    this.size,
    this.sha256, {
    this.kind = 'source',
  });
  final String receiptId;
  final String contentType;
  final int size;
  final String sha256;
  final String kind;

  /// Pages counted at completion.
  int? pages;
}
