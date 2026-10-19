import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:finance_core/finance_core.dart';
import 'package:meta/meta.dart';

import '../crypto/aead.dart';
import '../store/entity_ref.dart';
import '../store/store_context.dart';
import 'asset_record.dart';

/// Encrypted file storage for receipt originals, derivatives and previews
/// (REC 03, REC 08, NFR 10).
///
/// Each file is encrypted with AES-256-GCM under its own key, derived from
/// the workspace data key with HKDF and the asset id; the asset id is also
/// bound as associated data. Layout under the workspace directory:
/// `vault/assets/<id>.bin` (sources and derivatives),
/// `vault/previews/<id>.bin` and `vault/tmp/` for writes in progress.
///
/// File format: the 4 ASCII bytes `FSA1`, a 12-byte nonce, the ciphertext
/// and a 16-byte tag.
class ReceiptVault {
  ReceiptVault(this._ctx) {
    for (final dir in [assetsDir, previewsDir, tmpDir]) {
      dir.createSync(recursive: true);
    }
  }

  final StoreContext _ctx;

  static final _magic = ascii.encode('FSA1');

  /// Called with the temporary path before bytes are written; lets tests
  /// simulate I/O failures such as a full disk.
  @visibleForTesting
  void Function(String path)? debugBeforeWrite;

  /// Called after the file is in place and before metadata is committed;
  /// lets tests simulate a failure at that point.
  @visibleForTesting
  void Function()? debugBeforeCommit;

  Directory get _root => Directory('${_ctx.directory.path}/vault');
  Directory get assetsDir => Directory('${_root.path}/assets');
  Directory get previewsDir => Directory('${_root.path}/previews');
  Directory get tmpDir => Directory('${_root.path}/tmp');

  File fileFor(AssetRecord record) => _file(record.id, record.kind);

  File _file(String id, AssetKind kind) => File(
    '${kind == AssetKind.preview ? previewsDir.path : assetsDir.path}/$id.bin',
  );

  List<int> _aad(String id) => utf8.encode('finance_store/asset/v1/$id');

  Uint8List _encrypt(String id, List<int> bytes) {
    final sealed = sealAesGcm(_ctx.dataKey.assetKey(id), bytes, aad: _aad(id));
    return Uint8List(_magic.length + sealed.length)
      ..setAll(0, _magic)
      ..setAll(_magic.length, sealed);
  }

  /// Encrypts and durably stores [bytes], then commits the metadata; only
  /// then does the returned future complete ("Saved").
  ///
  /// The encrypted file is written to `vault/tmp`, flushed to disk and
  /// atomically renamed into place before the metadata transaction. A
  /// failure before the commit removes the file; a crash leaves an
  /// unreferenced file that is deleted on the next open. Write errors throw
  /// [StorageWriteException], with `lowStorage` set when the disk is full.
  Future<AssetRecord> saveAsset({
    required String ownerType,
    required String ownerId,
    required AssetKind kind,
    required String contentType,
    required List<int> bytes,
    String? assetId,
  }) async {
    final id = assetId ?? newId();
    final now = _ctx.now().toUtc();
    final record = AssetRecord(
      id: id,
      ownerType: ownerType,
      ownerId: ownerId,
      kind: kind,
      contentType: contentType,
      sizeBytes: bytes.length,
      sha256: hash.sha256.convert(bytes).toString(),
      storedBytes: 0,
      localState: AssetLocalState.present,
      uploadState: kind == AssetKind.preview
          ? AssetUploadState.notRequired
          : AssetUploadState.pending,
      uploadAttempts: 0,
      createdAt: now,
    );
    final file = _file(id, kind);
    final stored = _writeDurably(id, file, _encrypt(id, bytes));
    try {
      debugBeforeCommit?.call();
      _ctx.write(() {
        _insert(record, storedBytes: stored);
        if (kind != AssetKind.preview) {
          _ctx.record(
            _ctx.newCommand(
              type: CommandType.entityUpsert,
              entity: EntityRef(documentAssetType, id),
              payload: {'fields': record.toEntityJson()},
            ),
            undoable: false,
            description: 'Save document',
          );
        }
      });
    } catch (_) {
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    return asset(id)!;
  }

  int _writeDurably(String id, File target, Uint8List encrypted) {
    final temp = File('${tmpDir.path}/$id.part');
    try {
      debugBeforeWrite?.call(temp.path);
      final raf = temp.openSync(mode: FileMode.write);
      try {
        raf.writeFromSync(encrypted);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      temp.renameSync(target.path);
      return encrypted.length;
    } on FileSystemException catch (e) {
      if (temp.existsSync()) temp.deleteSync();
      final code = e.osError?.errorCode;
      // ENOSPC and EDQUOT on POSIX; ERROR_DISK_FULL and
      // ERROR_HANDLE_DISK_FULL on Windows.
      final low = code == 28 || code == 122 || code == 112 || code == 39;
      throw StorageWriteException(e.message, lowStorage: low, cause: e);
    }
  }

  void _insert(AssetRecord r, {required int storedBytes}) => _ctx.db.execute(
    'INSERT INTO assets (id, owner_type, owner_id, kind, content_type, '
    'size_bytes, sha256, stored_bytes, local_state, upload_state, '
    'upload_attempts, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
    [
      r.id,
      r.ownerType,
      r.ownerId,
      r.kind.name,
      r.contentType,
      r.sizeBytes,
      r.sha256,
      storedBytes,
      r.localState.name,
      uploadStateWire(r.uploadState),
      r.createdAt.toIso8601String(),
    ],
  );

  AssetRecord? asset(String id) {
    final rows = _ctx.db.select('SELECT * FROM assets WHERE id = ?', [id]);
    return rows.isEmpty ? null : AssetRecord.fromRow(rows.first);
  }

  List<AssetRecord> assetsFor(
    String ownerType,
    String ownerId, {
    bool includePreviews = false,
  }) => _ctx.db
      .select(
        'SELECT * FROM assets WHERE owner_type = ? AND owner_id = ?'
        "${includePreviews ? '' : " AND kind != 'preview'"} ORDER BY created_at",
        [ownerType, ownerId],
      )
      .map(AssetRecord.fromRow)
      .toList();

  List<AssetRecord> allAssets() => _ctx.db
      .select('SELECT * FROM assets ORDER BY created_at')
      .map(AssetRecord.fromRow)
      .toList();

  /// Decrypts an asset and verifies its SHA-256.
  Future<Uint8List> readAsset(String id) async {
    final record = asset(id);
    if (record == null) throw StateError('No asset $id');
    if (record.localState != AssetLocalState.present) {
      throw AssetNotLocalException(id, record.localState);
    }
    final bytes = _decrypt(id, fileFor(record).readAsBytesSync());
    if (hash.sha256.convert(bytes).toString() != record.sha256) {
      throw AssetCorruptException(id, 'checksum mismatch');
    }
    _ctx.db.execute('UPDATE assets SET last_accessed_at = ? WHERE id = ?', [
      _ctx.now().toUtc().toIso8601String(),
      id,
    ]);
    return bytes;
  }

  Uint8List _decrypt(String id, Uint8List stored) {
    if (stored.length < _magic.length ||
        ascii.decode(stored.sublist(0, 4), allowInvalid: true) != 'FSA1') {
      throw AssetCorruptException(id, 'unknown file format');
    }
    try {
      return openAesGcm(
        _ctx.dataKey.assetKey(id),
        Uint8List.sublistView(stored, _magic.length),
        aad: _aad(id),
      );
    } on DecryptionException {
      throw AssetCorruptException(id, 'authentication failed');
    }
  }

  /// Stores bytes downloaded from the cloud copy after checking the size
  /// and checksum recorded in the metadata.
  Future<AssetRecord> storeDownloaded(String id, List<int> bytes) async {
    final record = asset(id);
    if (record == null) throw StateError('No asset $id');
    if (bytes.length != record.sizeBytes ||
        hash.sha256.convert(bytes).toString() != record.sha256) {
      throw AssetCorruptException(id, 'download does not match checksum');
    }
    final stored = _writeDurably(id, fileFor(record), _encrypt(id, bytes));
    final at = _ctx.now().toUtc().toIso8601String();
    _ctx.write(
      () => _ctx.db.execute(
        "UPDATE assets SET local_state = 'present', stored_bytes = ?, "
        'cloud_confirmed_at = COALESCE(cloud_confirmed_at, ?), '
        "upload_state = CASE upload_state WHEN 'not_required' THEN 'uploaded' "
        'ELSE upload_state END WHERE id = ?',
        [stored, at, id],
      ),
    );
    return asset(id)!;
  }

  /// Records metadata of an asset created on another device; its bytes
  /// stay "pending" until downloaded.
  void applyRemoteMetadata(Map<String, Object?> json) {
    final id = json['id'] as String;
    final existing = asset(id);
    if (existing != null) return;
    _insert(
      AssetRecord(
        id: id,
        ownerType: json['ownerType'] as String,
        ownerId: json['ownerId'] as String,
        kind: AssetKind.values.byName(json['kind'] as String),
        contentType: json['contentType'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        storedBytes: 0,
        localState: AssetLocalState.remote,
        uploadState: AssetUploadState.notRequired,
        uploadAttempts: 0,
        createdAt: DateTime.parse(json['createdAt'] as String),
      ),
      storedBytes: 0,
    );
  }

  /// Handles a remote deletion of asset metadata. Bytes without a
  /// confirmed cloud copy are kept, so an unsynced original is never lost.
  void applyRemoteDeletion(String id) {
    final record = asset(id);
    if (record == null) return;
    if (record.localState == AssetLocalState.present && record.unsynced) {
      return;
    }
    _ctx.db.execute('DELETE FROM assets WHERE id = ?', [id]);
    final file = fileFor(record);
    if (file.existsSync()) file.deleteSync();
  }

  /// Deliberately deletes a document (REC 08). Financial entries that it
  /// supported are unaffected.
  Future<void> deleteAsset(String id) async {
    final record = asset(id);
    if (record == null) return;
    _ctx.write(() {
      _ctx.db.execute('DELETE FROM assets WHERE id = ?', [id]);
      final ref = EntityRef(documentAssetType, id);
      if (record.kind != AssetKind.preview && _ctx.state.json(ref) != null) {
        _ctx.record(
          _ctx.newCommand(
            type: CommandType.entityDelete,
            entity: ref,
            payload: const {},
          ),
          undoable: false,
          description: 'Delete document',
        );
      }
    });
    final file = fileFor(record);
    if (file.existsSync()) file.deleteSync();
  }

  // Upload bookkeeping used by the sync client --------------------------------

  /// Present sources and derivatives still to be uploaded, oldest first.
  List<AssetRecord> pendingUploads() => _ctx.db
      .select(
        "SELECT * FROM assets WHERE kind != 'preview' AND local_state = 'present' "
        "AND upload_state IN ('pending', 'uploading', 'failed') "
        'ORDER BY created_at',
      )
      .map(AssetRecord.fromRow)
      .toList();

  void markUploading(String id) => _ctx.db.execute(
    "UPDATE assets SET upload_state = 'uploading', "
    'upload_attempts = upload_attempts + 1 WHERE id = ?',
    [id],
  );

  /// Records a completed upload. [cloudConfirmed] means the server
  /// accepted completion, so a retrievable copy exists.
  void markUploaded(String id, {required bool cloudConfirmed}) =>
      _ctx.db.execute(
        "UPDATE assets SET upload_state = 'uploaded', last_error = NULL, "
        'cloud_confirmed_at = ? WHERE id = ?',
        [cloudConfirmed ? _ctx.now().toUtc().toIso8601String() : null, id],
      );

  void markUploadFailed(String id, String error) => _ctx.db.execute(
    "UPDATE assets SET upload_state = 'failed', last_error = ? WHERE id = ?",
    [error, id],
  );

  // Storage management -------------------------------------------------------

  /// Frees the local copy of an asset with a confirmed cloud copy. Unsynced
  /// originals and derivatives are never evicted (REC 08).
  Future<void> evictAsset(String id) async {
    final record = asset(id);
    if (record == null) throw StateError('No asset $id');
    if (record.kind == AssetKind.preview) {
      throw EvictionRefusedException(id, 'previews stay on the device');
    }
    if (record.localState != AssetLocalState.present) return;
    if (record.uploadState != AssetUploadState.uploaded ||
        record.cloudConfirmedAt == null) {
      throw EvictionRefusedException(id, 'no confirmed cloud copy');
    }
    _ctx.write(
      () => _ctx.db.execute(
        "UPDATE assets SET local_state = 'evicted', stored_bytes = 0 "
        'WHERE id = ?',
        [id],
      ),
    );
    final file = fileFor(record);
    if (file.existsSync()) file.deleteSync();
  }

  /// Evicts least recently used eligible assets until [bytes] are freed.
  Future<EvictionResult> evictToFree(int bytes) async {
    final candidates = _ctx.db.select(
      "SELECT * FROM assets WHERE kind != 'preview' AND local_state = 'present' "
      "AND upload_state = 'uploaded' AND cloud_confirmed_at IS NOT NULL "
      'ORDER BY COALESCE(last_accessed_at, created_at)',
    );
    var freed = 0;
    var count = 0;
    for (final row in candidates) {
      if (freed >= bytes) break;
      final record = AssetRecord.fromRow(row);
      await evictAsset(record.id);
      freed += record.storedBytes;
      count++;
    }
    return EvictionResult(count, freed);
  }

  StorageReport storageReport() {
    int sum(String where) =>
        (_ctx.db
                .select('SELECT SUM(stored_bytes) FROM assets WHERE $where')
                .first
                .values
                .first
            as int?) ??
        0;
    int count(String where) =>
        _ctx.db
                .select('SELECT count(*) FROM assets WHERE $where')
                .first
                .values
                .first
            as int;
    var dbBytes = 0;
    for (final suffix in ['', '-wal']) {
      final f = File('${_ctx.directory.path}/finance.db$suffix');
      if (f.existsSync()) dbBytes += f.lengthSync();
    }
    return StorageReport(
      assetCount: count('1 = 1'),
      originalBytes: sum("kind = 'source'"),
      derivativeBytes: sum("kind = 'derivative'"),
      previewBytes: sum("kind = 'preview'"),
      unsyncedBytes: sum("kind != 'preview' AND cloud_confirmed_at IS NULL"),
      evictableBytes: sum(
        "kind != 'preview' AND local_state = 'present' "
        "AND upload_state = 'uploaded' AND cloud_confirmed_at IS NOT NULL",
      ),
      evictedCount: count("local_state = 'evicted'"),
      imagePendingCount: count("local_state != 'present'"),
      pendingUploadCount: count(
        "kind != 'preview' AND upload_state IN ('pending', 'uploading', 'failed')",
      ),
      databaseBytes: dbBytes,
    );
  }

  /// Deletes partial writes and files without committed metadata, which a
  /// crash between writing a file and committing its metadata leaves
  /// behind. Returns how many files were removed.
  int removeOrphans() {
    var removed = 0;
    for (final f in tmpDir.listSync().whereType<File>()) {
      f.deleteSync();
      removed++;
    }
    final known = {
      for (final r in _ctx.db.select('SELECT id FROM assets'))
        r['id'] as String,
    };
    for (final dir in [assetsDir, previewsDir]) {
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final id = name.endsWith('.bin')
            ? name.substring(0, name.length - 4)
            : name;
        if (!known.contains(id)) {
          f.deleteSync();
          removed++;
        }
      }
    }
    return removed;
  }
}
