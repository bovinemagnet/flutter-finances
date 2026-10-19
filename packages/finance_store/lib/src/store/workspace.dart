import 'dart:convert';
import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import 'files.dart';

/// Whether the workspace synchronises with the server (SYNC 01, SEC 01).
enum SyncMode { local, synced }

/// Workspace-wide settings stored in the encrypted database.
@immutable
class WorkspaceSettings {
  const WorkspaceSettings({
    required this.workspaceId,
    required this.deviceId,
    required this.currency,
    required this.timezone,
    required this.locale,
    required this.syncMode,
    required this.createdAt,
  });

  factory WorkspaceSettings.read(Database db) {
    final row = db.select('SELECT * FROM workspace WHERE id = 1').first;
    return WorkspaceSettings(
      workspaceId: row['workspace_id'] as String,
      deviceId: row['device_id'] as String,
      currency: Currency(
        row['currency'] as String,
        row['currency_exponent'] as int,
      ),
      timezone: row['timezone'] as String,
      locale: row['locale'] as String,
      syncMode: SyncMode.values.byName(row['sync_mode'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  final String workspaceId;
  final String deviceId;

  /// One currency per workspace with its explicit minor-unit exponent.
  final Currency currency;

  /// IANA timezone deciding which local date is "today".
  final String timezone;
  final String locale;
  final SyncMode syncMode;
  final DateTime createdAt;

  void insert(Database db) => db.execute(
    'INSERT INTO workspace (id, workspace_id, device_id, currency, '
    'currency_exponent, timezone, locale, sync_mode, created_at) '
    'VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      workspaceId,
      deviceId,
      currency.code,
      currency.exponent,
      timezone,
      locale,
      syncMode.name,
      createdAt.toUtc().toIso8601String(),
    ],
  );
}

class WorkspaceExistsException implements Exception {
  WorkspaceExistsException(this.path);
  final String path;

  @override
  String toString() => 'A workspace already exists at $path';
}

class WorkspaceNotFoundException implements Exception {
  WorkspaceNotFoundException(this.path);
  final String path;

  @override
  String toString() => 'No workspace at $path';
}

/// Thrown when opening a restored workspace that has not been activated.
class WorkspaceNotActiveException implements Exception {
  WorkspaceNotActiveException(this.state);
  final String state;

  @override
  String toString() => 'The workspace is $state and has not been activated';
}

/// The plaintext `workspace.json` beside the database: the format version,
/// lifecycle state and the non-secret description of the key protection.
class WorkspaceDescriptor {
  WorkspaceDescriptor({required this.key, this.state = 'active'});

  factory WorkspaceDescriptor.read(Directory dir) {
    final file = File(pathIn(dir));
    if (!file.existsSync()) throw WorkspaceNotFoundException(dir.path);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    if (json['format'] != format || json['formatVersion'] != 1) {
      throw FormatException('Unsupported workspace descriptor', file.path);
    }
    return WorkspaceDescriptor(
      key: (json['key'] as Map).cast<String, Object?>(),
      state: json['state'] as String,
    );
  }

  static const format = 'finance_store.workspace';
  static const fileName = 'workspace.json';
  static String pathIn(Directory dir) => '${dir.path}/$fileName';

  Map<String, Object?> key;

  /// `active`, or `staged` for a restore awaiting activation.
  String state;

  void write(Directory dir) => writeFileAtomically(
    pathIn(dir),
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'formatVersion': 1,
        'state': state,
        'key': key,
      }),
    ),
  );
}
