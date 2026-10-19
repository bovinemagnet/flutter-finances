import 'package:meta/meta.dart';

const syncSchemaVersion = 1;

enum CommandType {
  journalPost('journal.post'),
  journalCorrect('journal.correct'),
  entityUpsert('entity.upsert'),
  entityDelete('entity.delete');

  const CommandType(this.wire);
  final String wire;

  static CommandType fromWire(String wire) => values.firstWhere(
    (t) => t.wire == wire,
    orElse: () => throw FormatException('Unknown command type', wire),
  );
}

enum CommandStatus {
  applied,
  previouslyApplied('previously_applied'),
  conflict,
  validationFailed('validation_failed'),
  permissionDenied('permission_denied');

  const CommandStatus([this._wire]);
  final String? _wire;
  String get wire => _wire ?? name;

  static CommandStatus fromWire(String wire) => values.firstWhere(
    (s) => s.wire == wire,
    orElse: () => throw FormatException('Unknown status', wire),
  );
}

/// A versioned command envelope (spec/sync/protocol.md).
@immutable
class SyncCommand {
  const SyncCommand({
    required this.commandId,
    required this.workspaceId,
    required this.deviceId,
    required this.type,
    required this.entityType,
    required this.entityId,
    required this.baseRevision,
    required this.payload,
    this.schemaVersion = syncSchemaVersion,
  });

  factory SyncCommand.fromJson(Map<String, Object?> json) => SyncCommand(
    commandId: json['commandId'] as String,
    workspaceId: json['workspaceId'] as String,
    deviceId: json['deviceId'] as String,
    type: CommandType.fromWire(json['type'] as String),
    entityType: json['entityType'] as String,
    entityId: json['entityId'] as String,
    baseRevision: json['baseRevision'] as int,
    schemaVersion: json['schemaVersion'] as int,
    payload: (json['payload'] as Map).cast<String, Object?>(),
  );

  final String commandId;
  final String workspaceId;
  final String deviceId;
  final CommandType type;
  final String entityType;
  final String entityId;
  final int baseRevision;
  final int schemaVersion;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
    'commandId': commandId,
    'workspaceId': workspaceId,
    'deviceId': deviceId,
    'type': type.wire,
    'entityType': entityType,
    'entityId': entityId,
    'baseRevision': baseRevision,
    'schemaVersion': schemaVersion,
    'payload': payload,
  };
}

@immutable
class CommandResult {
  const CommandResult({
    required this.commandId,
    required this.status,
    this.revision,
    this.cursor,
    this.errors = const [],
    this.conflict,
  });

  factory CommandResult.fromJson(Map<String, Object?> json) => CommandResult(
    commandId: json['commandId'] as String,
    status: CommandStatus.fromWire(json['status'] as String),
    revision: json['revision'] as int?,
    cursor: json['cursor'] as String?,
    errors: (json['errors'] as List? ?? const []).cast<String>(),
    conflict: json['conflict'] == null
        ? null
        : ConflictInfo.fromJson(
            (json['conflict'] as Map).cast<String, Object?>(),
          ),
  );

  final String commandId;
  final CommandStatus status;
  final int? revision;
  final String? cursor;
  final List<String> errors;
  final ConflictInfo? conflict;

  bool get accepted =>
      status == CommandStatus.applied ||
      status == CommandStatus.previouslyApplied;
}

@immutable
class ConflictInfo {
  const ConflictInfo(this.serverRevision, this.serverState, this.fields);

  factory ConflictInfo.fromJson(Map<String, Object?> json) => ConflictInfo(
    json['serverRevision'] as int,
    (json['serverState'] as Map?)?.cast<String, Object?>(),
    (json['fields'] as List? ?? const []).cast<String>(),
  );

  final int serverRevision;
  final Map<String, Object?>? serverState;
  final List<String> fields;
}

/// One entry of the server change feed.
@immutable
class ChangeRecord {
  const ChangeRecord({
    required this.entityType,
    required this.entityId,
    required this.revision,
    required this.deleted,
    this.data,
  });

  factory ChangeRecord.fromJson(Map<String, Object?> json) => ChangeRecord(
    entityType: json['entityType'] as String,
    entityId: json['entityId'] as String,
    revision: json['revision'] as int,
    deleted: json['op'] == 'delete',
    data: (json['data'] as Map?)?.cast<String, Object?>(),
  );

  final String entityType;
  final String entityId;
  final int revision;
  final bool deleted;
  final Map<String, Object?>? data;
}
