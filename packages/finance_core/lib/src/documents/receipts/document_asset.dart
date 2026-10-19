import 'package:meta/meta.dart';

import '../validation/content_type.dart';
import 'receipt_states.dart';

/// Whether an asset is the file as captured or imported, or the confirmed
/// readable derivative (cropped, deskewed, enhanced) (REC 02).
enum AssetKind { source, readableDerivative }

/// One stored file belonging to a receipt (REC 02, REC 08, SYNC 05).
@immutable
class DocumentAsset implements UploadStateHolder {
  const DocumentAsset({
    required this.id,
    required this.receiptId,
    required this.kind,
    required this.contentType,
    required this.sha256,
    required this.sizeBytes,
    required this.pageCount,
    required this.createdAt,
    this.presentLocally = true,
    this.uploadState = UploadState.localOnly,
    this.cloudCopyConfirmed = false,
  });

  final String id;
  final String receiptId;
  final AssetKind kind;
  final DocumentContentType contentType;

  /// Lower-case hexadecimal SHA-256 of the bytes.
  final String sha256;
  final int sizeBytes;
  final int pageCount;
  final DateTime createdAt;

  /// Whether the bytes are in this device's protected storage.
  final bool presentLocally;
  @override
  final UploadState uploadState;

  /// Whether the server confirmed a retrievable copy (completion verified
  /// and the asset available), which is required before eviction.
  final bool cloudCopyConfirmed;

  DocumentAsset _copy({
    bool? presentLocally,
    UploadState? uploadState,
    bool? cloudCopyConfirmed,
  }) => DocumentAsset(
    id: id,
    receiptId: receiptId,
    kind: kind,
    contentType: contentType,
    sha256: sha256,
    sizeBytes: sizeBytes,
    pageCount: pageCount,
    createdAt: createdAt,
    presentLocally: presentLocally ?? this.presentLocally,
    uploadState: uploadState ?? this.uploadState,
    cloudCopyConfirmed: cloudCopyConfirmed ?? this.cloudCopyConfirmed,
  );

  DocumentAsset withUploadEvent(UploadEvent event) =>
      _copy(uploadState: nextUploadState(uploadState, event));

  DocumentAsset withCloudCopyConfirmed() {
    if (uploadState != UploadState.uploaded) {
      throw StateError('Asset $id is not uploaded yet');
    }
    return _copy(cloudCopyConfirmed: true);
  }

  /// The asset after its local bytes were removed from the cache.
  DocumentAsset evicted() {
    final status = evictionStatus(this);
    if (status != EvictionStatus.evictable) {
      throw StateError('Asset $id cannot be evicted: ${status.name}');
    }
    return _copy(presentLocally: false);
  }

  /// The asset after its bytes were downloaded again.
  DocumentAsset restoredLocally() => _copy(presentLocally: true);
}

enum EvictionStatus {
  evictable,
  notPresent,

  /// Includes local-only, queued, uploading and failed uploads: an
  /// unsynced original is never evicted.
  notUploaded,
  cloudCopyUnconfirmed,
}

/// Whether the local copy may be dropped from the cache (REC 08).
EvictionStatus evictionStatus(DocumentAsset asset) {
  if (!asset.presentLocally) return EvictionStatus.notPresent;
  if (asset.uploadState != UploadState.uploaded) {
    return EvictionStatus.notUploaded;
  }
  if (!asset.cloudCopyConfirmed) return EvictionStatus.cloudCopyUnconfirmed;
  return EvictionStatus.evictable;
}
