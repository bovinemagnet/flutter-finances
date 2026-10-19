import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';

import '../crypto/key_protection.dart';
import '../db/search_index.dart';
import '../store/entity_ref.dart';
import '../store/finance_store.dart';
import '../store/local_state.dart';
import '../store/store_context.dart';
import '../store/workspace.dart';
import '../vault/asset_record.dart';
import 'archive_container.dart';
import 'backup_export.dart';

/// What a staged restore contains and whether it verified (DATA 03).
@immutable
class RestorePreview {
  const RestorePreview({
    required this.sourceWorkspaceId,
    required this.createdAt,
    required this.formatVersion,
    required this.schemaVersion,
    required this.schemaCompatible,
    required this.expectedCounts,
    required this.restoredCounts,
    required this.checksumFailures,
    required this.missingAssets,
    required this.unavailableAssets,
    required this.unbalancedJournals,
    required this.pendingLocalChanges,
    required this.acceptedCursor,
  });

  final String? sourceWorkspaceId;
  final DateTime? createdAt;
  final int? formatVersion;
  final int? schemaVersion;
  final bool schemaCompatible;

  /// Counts from the manifest and counts actually restored.
  final Map<String, Object?> expectedCounts;
  final Map<String, Object?> restoredCounts;

  /// Entries whose SHA-256 differs from the manifest, or that are missing
  /// or not listed in it.
  final List<String> checksumFailures;

  /// Assets the archive should contain but does not (or that failed
  /// verification).
  final List<String> missingAssets;

  /// Assets that were not on the exporting device (evicted or never
  /// downloaded), so the archive never held them.
  final List<String> unavailableAssets;
  final List<String> unbalancedJournals;

  /// Local commands that had not been accepted when exporting, recorded
  /// separately from the accepted state and never replayed into a live
  /// workspace.
  final List<SyncCommand> pendingLocalChanges;

  /// The change cursor the exporting device had reached.
  final String? acceptedCursor;

  bool get countsMatch =>
      jsonEncode(_canonical(expectedCounts)) ==
      jsonEncode(_canonical(restoredCounts));

  bool get canActivate =>
      schemaCompatible &&
      checksumFailures.isEmpty &&
      missingAssets.isEmpty &&
      unbalancedJournals.isEmpty &&
      countsMatch;
}

Object? _canonical(Object? value) => value is Map
    ? {
        for (final k in (value.keys.map((k) => '$k').toList()..sort()))
          k: _canonical(value[k]),
      }
    : value;

class RestoreVerificationException implements Exception {
  RestoreVerificationException(this.preview);
  final RestorePreview preview;

  @override
  String toString() => 'The restored workspace did not verify; see preview';
}

/// A restore held in an isolated staging workspace until [activate].
class StagedRestore {
  StagedRestore._(
    this.stagingDirectory,
    this.target,
    this.preview,
    this._keyProtection,
    this._validators,
    this._extractors,
  );

  final Directory stagingDirectory;
  final Directory target;
  final RestorePreview preview;
  final KeyProtection _keyProtection;
  final Map<String, EntityValidator> _validators;
  final Map<String, SearchExtractor> _extractors;

  /// Moves the verified workspace into [target] and opens it. Refused
  /// unless [RestorePreview.canActivate].
  Future<FinanceStore> activate() async {
    if (!preview.canActivate) throw RestoreVerificationException(preview);
    if (target.existsSync() &&
        File(WorkspaceDescriptor.pathIn(target)).existsSync()) {
      throw WorkspaceExistsException(target.path);
    }
    if (target.existsSync()) target.deleteSync(recursive: true);
    stagingDirectory.renameSync(target.path);
    WorkspaceDescriptor.read(target)
      ..state = 'active'
      ..write(target);
    return FinanceStore.open(
      target,
      keyProtection: _keyProtection,
      validators: _validators,
      searchExtractors: _extractors,
    );
  }

  /// Deletes the staging workspace.
  Future<void> discard() async {
    if (stagingDirectory.existsSync()) {
      stagingDirectory.deleteSync(recursive: true);
    }
  }
}

/// Restores [archive] into a new, isolated workspace beside [target] and
/// verifies checksums, schema compatibility, balanced journals, record
/// counts and missing assets (DATA 03). Nothing touches [target] until the
/// returned [StagedRestore] is activated.
///
/// The restored workspace gets a new workspace id and device id and starts
/// local only, so an old backup is never replayed into a live workspace.
/// Its outbox is rebuilt from the restored state in dependency order, so
/// enabling sync later uploads it as a new workspace.
Future<StagedRestore> stageRestore(
  File archive, {
  required String recoverySecret,
  required Directory target,
  required KeyProtection keyProtection,
  Map<String, EntityValidator> validators = const {},
  Map<String, SearchExtractor> searchExtractors = const {},
}) async {
  if (File(WorkspaceDescriptor.pathIn(target)).existsSync()) {
    throw WorkspaceExistsException(target.path);
  }
  final staging = Directory('${target.path}.restore-staging');
  if (staging.existsSync()) staging.deleteSync(recursive: true);

  final reader = await ArchiveReader.open(archive, recoverySecret);
  FinanceStore? store;
  try {
    final data = <String, Object?>{};
    final hashes = <String, String>{};
    final assetMeta = <String, Map<String, Object?>>{};
    final restoredFiles = <String>{};
    final failures = <String>[];
    Map<String, Object?>? manifest;
    for (var e = reader.next(); e != null; e = reader.next()) {
      final name = e.name;
      hashes[name] = hash.sha256.convert(e.bytes).toString();
      if (name == 'manifest.json') {
        manifest = _decode(e.bytes) as Map<String, Object?>;
      } else if (name == 'data/workspace.json') {
        final ws = _decode(e.bytes) as Map<String, Object?>;
        data[name] = ws;
        store = await FinanceStore.create(
          staging,
          keyProtection: keyProtection,
          currency: Currency(ws['currency'] as String, ws['exponent'] as int),
          timezone: ws['timezone'] as String,
          locale: ws['locale'] as String,
          validators: validators,
          searchExtractors: searchExtractors,
          state: 'staged',
        );
      } else if (name == 'data/assets.json') {
        for (final a
            in (_decode(e.bytes) as List).cast<Map<String, Object?>>()) {
          assetMeta[a['id'] as String] = a;
        }
      } else if (name.startsWith('data/') || name == 'pending_commands.json') {
        data[name] = _decode(e.bytes);
      } else if (name.startsWith('files/')) {
        final id = name.substring('files/'.length);
        final meta = assetMeta[id];
        if (store == null || meta == null) {
          failures.add(name);
          continue;
        }
        try {
          await store.vault.importAsset(meta, e.bytes);
          restoredFiles.add(id);
        } on AssetCorruptException {
          failures.add(name);
        }
      }
    }
    if (store == null || manifest == null) {
      throw BackupFormatException('The archive has no workspace or manifest');
    }

    final formatVersion = manifest['formatVersion'] as int?;
    final schemaVersion = manifest['schemaVersion'] as int?;
    final compatible =
        manifest['format'] == BackupContainer.format &&
        formatVersion != null &&
        formatVersion <= backupFormatVersion &&
        schemaVersion != null &&
        schemaVersion <= syncSchemaVersion;

    final listed = (manifest['files'] as Map? ?? const {})
        .cast<String, Object?>();
    for (final MapEntry(key: name, value: info) in listed.entries) {
      final expected = (info as Map)['sha256'];
      if (hashes[name] == null) {
        if (!name.startsWith('files/')) failures.add(name);
      } else if (hashes[name] != expected) {
        failures.add(name);
      }
    }
    for (final name in hashes.keys) {
      if (name != 'manifest.json' && !listed.containsKey(name)) {
        failures.add(name);
      }
    }

    final missing = <String>[];
    final unavailable = <String>[];
    for (final MapEntry(key: id, value: meta) in assetMeta.entries) {
      if (meta['file'] == null) {
        unavailable.add(id);
      } else if (!restoredFiles.contains(id)) {
        missing.add(id);
      }
    }

    final unbalanced = <String>[];
    var restoredCounts = <String, Object?>{};
    if (compatible) {
      unbalanced.addAll(
        _applyData(store.context, data, assetMeta, restoredFiles),
      );
      restoredCounts = _counts(store.context);
    }
    final pending = [
      for (final c
          in (data['pending_commands.json'] as List? ?? const [])
              .cast<Map<String, Object?>>())
        SyncCommand.fromJson(c),
    ];
    final accepted = (manifest['acceptedState'] as Map?)
        ?.cast<String, Object?>();
    final ws = (manifest['workspace'] as Map?)?.cast<String, Object?>();
    final preview = RestorePreview(
      sourceWorkspaceId: ws?['workspaceId'] as String?,
      createdAt: manifest['createdAt'] == null
          ? null
          : DateTime.parse(manifest['createdAt'] as String),
      formatVersion: formatVersion,
      schemaVersion: schemaVersion,
      schemaCompatible: compatible,
      expectedCounts: (manifest['counts'] as Map? ?? const {})
          .cast<String, Object?>(),
      restoredCounts: restoredCounts,
      checksumFailures: failures.toSet().toList(),
      missingAssets: missing,
      unavailableAssets: unavailable,
      unbalancedJournals: unbalanced,
      pendingLocalChanges: pending,
      acceptedCursor: accepted?['cursor'] as String?,
    );
    await store.close();
    store = null;
    return StagedRestore._(
      staging,
      target,
      preview,
      keyProtection,
      validators,
      searchExtractors,
    );
  } catch (_) {
    await store?.close();
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  } finally {
    reader.close();
  }
}

Object? _decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

/// Writes the archive's records into the staging workspace and rebuilds
/// its outbox. Returns journals that do not balance.
List<String> _applyData(
  StoreContext ctx,
  Map<String, Object?> data,
  Map<String, Map<String, Object?>> assetMeta,
  Set<String> restoredFiles,
) {
  List<Map<String, Object?>> list(String name) =>
      (data[name] as List? ?? const []).cast<Map<String, Object?>>();
  Map<String, Object?> strip(Map<String, Object?> m) =>
      {...m}..remove('revision');
  final unbalanced = <String>[];
  ctx.write(() {
    void put(EntityRef ref, Map<String, Object?> json) {
      ctx.state.put(ref, json, revision: 0);
      _command(ctx, CommandType.entityUpsert, ref, {'fields': json});
    }

    for (final a in list('data/accounts.json')) {
      put(EntityRef(EntityTypes.account, a['id'] as String), strip(a));
    }
    for (final c in list('data/categories.json')) {
      put(EntityRef(EntityTypes.category, c['id'] as String), strip(c));
    }
    for (final e in list('data/entities.json')) {
      put(
        EntityRef(e['entityType'] as String, e['id'] as String),
        (e['json'] as Map).cast<String, Object?>(),
      );
    }
    for (final MapEntry(key: id, value: meta) in assetMeta.entries) {
      if (!restoredFiles.contains(id) &&
          meta['kind'] != AssetKind.preview.name) {
        // Known but absent: shown as "Image pending", never fabricated.
        ctx.db.execute(
          'INSERT OR IGNORE INTO assets (id, owner_type, owner_id, kind, '
          'content_type, size_bytes, sha256, stored_bytes, local_state, '
          'upload_state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '
          "'remote', 'not_required', ?)",
          [
            id,
            meta['ownerType'],
            meta['ownerId'],
            meta['kind'],
            meta['contentType'],
            meta['sizeBytes'],
            meta['sha256'],
            meta['createdAt'],
          ],
        );
      }
    }

    final journals = <String, Journal>{};
    for (final j in list('data/journals.json')) {
      try {
        final journal = journalFromJson(strip(j), ctx.currency);
        journals[journal.id] = journal;
        if (validatePostings(journal.postings).isNotEmpty) {
          unbalanced.add(journal.id);
        }
        ctx.state.put(
          EntityRef(EntityTypes.journal, journal.id),
          journalToJson(journal),
          revision: 0,
        );
      } on Object {
        unbalanced.add('${j['id']}');
      }
    }
    _journalCommands(ctx, journals);
  });
  return unbalanced;
}

/// Recreates the history as commands the server can apply in order: each
/// original is posted, then corrected with its reversal and replacement,
/// following replacement chains.
void _journalCommands(StoreContext ctx, Map<String, Journal> journals) {
  final reversalOf = <String, Journal>{};
  final replacementOf = <String, Journal>{};
  for (final j in journals.values) {
    if (j.reversalOf != null) reversalOf[j.reversalOf!] = j;
    if (j.replaces != null) replacementOf[j.replaces!] = j;
  }
  final done = <String>{};
  void post(Journal j) {
    final asPosted = j.status == JournalStatus.reversed
        ? j.copyWith(status: JournalStatus.posted)
        : j;
    _command(
      ctx,
      CommandType.journalPost,
      EntityRef(EntityTypes.journal, j.id),
      {'journal': journalToJson(asPosted)},
    );
    done.add(j.id);
  }

  void chain(Journal j) {
    if (j.status != JournalStatus.reversed) return;
    final reversal = reversalOf[j.id];
    if (reversal == null) return;
    final replacement = replacementOf[j.id];
    _command(
      ctx,
      CommandType.journalCorrect,
      EntityRef(EntityTypes.journal, j.id),
      {
        'originalId': j.id,
        'reversal': journalToJson(reversal),
        'replacement': replacement == null ? null : journalToJson(replacement),
      },
      extraKeys: [
        EntityRef(EntityTypes.journal, reversal.id),
        if (replacement != null) EntityRef(EntityTypes.journal, replacement.id),
      ],
    );
    done.addAll([reversal.id, ?replacement?.id]);
    if (replacement != null) chain(replacement);
  }

  final roots =
      journals.values
          .where((j) => j.reversalOf == null && j.replaces == null)
          .toList()
        ..sort((a, b) {
          final byTime = a.enteredAt.compareTo(b.enteredAt);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
  for (final root in roots) {
    post(root);
    chain(root);
  }
  for (final j in journals.values) {
    if (!done.contains(j.id)) post(j);
  }
}

void _command(
  StoreContext ctx,
  CommandType type,
  EntityRef ref,
  Map<String, Object?> payload, {
  List<EntityRef> extraKeys = const [],
}) {
  ctx.outbox.add(
    ctx.newCommand(type: type, entity: ref, payload: payload, baseRevision: 0),
    <EntityRef, EntitySnapshot?>{ref: null, for (final k in extraKeys) k: null},
    undoable: false,
    description: 'Restored',
  );
}

Map<String, Object?> _counts(StoreContext ctx) {
  int count(String sql) => ctx.db.select(sql).first.values.first as int;
  final entities = <String, Object?>{
    for (final r in ctx.db.select(
      'SELECT entity_type, count(*) n FROM entities WHERE deleted = 0 '
      'GROUP BY entity_type',
    ))
      r['entity_type'] as String: r['n'],
  };
  return {
    'accounts': count('SELECT count(*) FROM accounts WHERE deleted = 0'),
    'categories': count('SELECT count(*) FROM categories WHERE deleted = 0'),
    'journals': count('SELECT count(*) FROM journals WHERE deleted = 0'),
    'postings': count('SELECT count(*) FROM postings'),
    'entities': entities,
    'assets': count('SELECT count(*) FROM assets'),
    'assetFiles': count(
      "SELECT count(*) FROM assets WHERE local_state = 'present'",
    ),
  };
}
