import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// Entity type through which asset metadata is synchronised, so another
/// device can show "Image pending" before the bytes arrive (SYNC 05).
const documentAssetType = 'documentAsset';

/// `source` is the imported original, `derivative` the confirmed readable
/// copy, and `preview` a small local thumbnail that is never uploaded.
enum VaultAssetKind { source, derivative, preview }

/// Whether the encrypted bytes are on this device.
enum AssetLocalState {
  present,

  /// Removed locally after a confirmed cloud copy; downloadable again.
  evicted,

  /// Known from another device; the bytes have not been downloaded.
  remote,
}

enum AssetUploadState { notRequired, pending, uploading, uploaded, failed }

String _wire(Enum e) => switch (e) {
  AssetUploadState.notRequired => 'not_required',
  _ => e.name,
};

String uploadStateWire(AssetUploadState s) => _wire(s);

AssetUploadState uploadStateFromWire(String wire) =>
    AssetUploadState.values.firstWhere((s) => _wire(s) == wire);

/// Metadata of one stored file.
@immutable
class AssetRecord {
  const AssetRecord({
    required this.id,
    required this.ownerType,
    required this.ownerId,
    required this.kind,
    required this.contentType,
    required this.sizeBytes,
    required this.sha256,
    required this.storedBytes,
    required this.localState,
    required this.uploadState,
    required this.uploadAttempts,
    required this.createdAt,
    this.lastError,
    this.cloudConfirmedAt,
    this.lastAccessedAt,
  });

  factory AssetRecord.fromRow(Row row) => AssetRecord(
    id: row['id'] as String,
    ownerType: row['owner_type'] as String,
    ownerId: row['owner_id'] as String,
    kind: VaultAssetKind.values.byName(row['kind'] as String),
    contentType: row['content_type'] as String,
    sizeBytes: row['size_bytes'] as int,
    sha256: row['sha256'] as String,
    storedBytes: row['stored_bytes'] as int,
    localState: AssetLocalState.values.byName(row['local_state'] as String),
    uploadState: uploadStateFromWire(row['upload_state'] as String),
    uploadAttempts: row['upload_attempts'] as int,
    createdAt: DateTime.parse(row['created_at'] as String),
    lastError: row['last_error'] as String?,
    cloudConfirmedAt: row['cloud_confirmed_at'] == null
        ? null
        : DateTime.parse(row['cloud_confirmed_at'] as String),
    lastAccessedAt: row['last_accessed_at'] == null
        ? null
        : DateTime.parse(row['last_accessed_at'] as String),
  );

  final String id;

  /// The entity the file belongs to, usually a `receipt`.
  final String ownerType;
  final String ownerId;
  final VaultAssetKind kind;
  final String contentType;

  /// Plaintext size and SHA-256 (hex), verified on read and download.
  final int sizeBytes;
  final String sha256;

  /// Encrypted size on disk; 0 when not present.
  final int storedBytes;
  final AssetLocalState localState;
  final AssetUploadState uploadState;
  final int uploadAttempts;
  final DateTime createdAt;
  final String? lastError;

  /// When the server confirmed a retrievable cloud copy.
  final DateTime? cloudConfirmedAt;
  final DateTime? lastAccessedAt;

  /// The bytes are not on this device yet ("Image pending").
  bool get imagePending => localState != AssetLocalState.present;

  /// Uploadable and not yet confirmed in the cloud.
  bool get unsynced =>
      kind != VaultAssetKind.preview && cloudConfirmedAt == null;

  /// Metadata synchronised to other devices.
  Map<String, Object?> toEntityJson() => {
    'id': id,
    'ownerType': ownerType,
    'ownerId': ownerId,
    'kind': kind.name,
    'contentType': contentType,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// Device storage used by the workspace (NFR 10).
@immutable
class StorageReport {
  const StorageReport({
    required this.assetCount,
    required this.originalBytes,
    required this.derivativeBytes,
    required this.previewBytes,
    required this.unsyncedBytes,
    required this.evictableBytes,
    required this.evictedCount,
    required this.imagePendingCount,
    required this.pendingUploadCount,
    required this.databaseBytes,
  });

  final int assetCount;
  final int originalBytes;
  final int derivativeBytes;
  final int previewBytes;

  /// Local bytes without a confirmed cloud copy; never evicted.
  final int unsyncedBytes;

  /// Local bytes that could be freed and downloaded again.
  final int evictableBytes;
  final int evictedCount;
  final int imagePendingCount;
  final int pendingUploadCount;
  final int databaseBytes;

  int get totalBytes =>
      originalBytes + derivativeBytes + previewBytes + databaseBytes;
}

@immutable
class EvictionResult {
  const EvictionResult(this.evictedCount, this.freedBytes);
  final int evictedCount;
  final int freedBytes;
}

/// Writing to protected storage failed; nothing was recorded as saved.
class StorageWriteException implements Exception {
  StorageWriteException(this.message, {this.lowStorage = false, this.cause});
  final String message;

  /// The device is out of space (or quota); show the storage-full state.
  final bool lowStorage;
  final Object? cause;

  @override
  String toString() =>
      'StorageWriteException(${lowStorage ? 'low storage: ' : ''}$message)';
}

class AssetNotLocalException implements Exception {
  AssetNotLocalException(this.assetId, this.state);
  final String assetId;
  final AssetLocalState state;

  @override
  String toString() => 'Asset $assetId is ${state.name}; download it first';
}

class AssetCorruptException implements Exception {
  AssetCorruptException(this.assetId, this.reason);
  final String assetId;
  final String reason;

  @override
  String toString() => 'Asset $assetId failed verification: $reason';
}

class EvictionRefusedException implements Exception {
  EvictionRefusedException(this.assetId, this.reason);
  final String assetId;
  final String reason;

  @override
  String toString() => 'Asset $assetId cannot be evicted: $reason';
}
