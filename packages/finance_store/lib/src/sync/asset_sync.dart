import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../store/entity_ref.dart';
import '../store/store_context.dart';
import '../vault/asset_record.dart';
import '../vault/receipt_vault.dart';
import 'transport.dart';

enum UploadPhase { started, sending, completed, failed, paused }

/// Progress of receipt uploads, for the "uploading" indicator (Journey E).
@immutable
class UploadProgress {
  const UploadProgress({
    required this.assetId,
    required this.phase,
    required this.bytesSent,
    required this.totalBytes,
    required this.completedAssets,
    required this.totalAssets,
  });

  final String assetId;
  final UploadPhase phase;
  final int bytesSent;
  final int totalBytes;
  final int completedAssets;
  final int totalAssets;
}

@immutable
class UploadSummary {
  const UploadSummary({
    required this.uploaded,
    required this.failed,
    required this.pausedOnMetered,
    required this.awaitingMetadata,
  });

  final List<String> uploaded;
  final List<String> failed;

  /// Large uploads held back on a metered connection.
  final List<String> pausedOnMetered;

  /// Assets whose receipt metadata the server has not accepted yet.
  final List<String> awaitingMetadata;
}

/// The asset is known but its upload has not completed and passed the
/// server's checks yet ("Image pending").
class AssetNotYetAvailableException implements Exception {
  AssetNotYetAvailableException(this.assetId);
  final String assetId;

  @override
  String toString() => 'Asset $assetId is not available yet';
}

/// Uploads receipt files directly to object storage through short-lived
/// intents, independently of financial commands (SYNC 05).
class AssetSync {
  AssetSync({
    required this.ctx,
    required this.vault,
    required this.transport,
    this.concurrency = 2,
    this.chunkSize = 64 * 1024,
  });

  final StoreContext ctx;
  final ReceiptVault vault;
  final SyncTransport transport;

  /// Uploads in flight at once.
  final int concurrency;
  final int chunkSize;

  /// Uploads every pending source and derivative whose metadata the server
  /// knows, at most [concurrency] at a time, retrying with backoff. When
  /// [meteredConnection] is true, assets larger than [largeAssetBytes] wait
  /// for an unmetered connection.
  Future<UploadSummary> uploadPending({
    bool meteredConnection = false,
    int largeAssetBytes = 1024 * 1024,
    void Function(UploadProgress progress)? onProgress,
  }) async {
    final ready = <AssetRecord>[];
    final paused = <String>[];
    final waiting = <String>[];
    for (final asset in vault.pendingUploads()) {
      final known =
          ctx.state.revision(EntityRef(asset.ownerType, asset.ownerId)) > 0 &&
          ctx.state.revision(EntityRef(documentAssetType, asset.id)) > 0;
      if (!known) {
        waiting.add(asset.id);
      } else if (meteredConnection && asset.sizeBytes > largeAssetBytes) {
        paused.add(asset.id);
      } else {
        ready.add(asset);
      }
    }
    final uploaded = <String>[];
    final failed = <String>[];
    var completed = 0;
    void report(AssetRecord a, UploadPhase phase, int sent) => onProgress?.call(
      UploadProgress(
        assetId: a.id,
        phase: phase,
        bytesSent: sent,
        totalBytes: a.sizeBytes,
        completedAssets: completed,
        totalAssets: ready.length,
      ),
    );
    for (final id in paused) {
      report(vault.asset(id)!, UploadPhase.paused, 0);
    }
    final queue = [...ready];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final asset = queue.removeAt(0);
        try {
          await _upload(asset, report);
          completed++;
          uploaded.add(asset.id);
          report(asset, UploadPhase.completed, asset.sizeBytes);
        } on Object catch (e) {
          vault.markUploadFailed(asset.id, '$e');
          failed.add(asset.id);
          report(asset, UploadPhase.failed, 0);
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < ready.length; i++) worker(),
    ]);
    return UploadSummary(
      uploaded: uploaded,
      failed: failed,
      pausedOnMetered: paused,
      awaitingMetadata: waiting,
    );
  }

  /// Intent, PUT, then complete. Each step is retried by the transport; a
  /// restart requests a fresh intent for the same object, and completing
  /// twice never creates a second receipt.
  Future<void> _upload(
    AssetRecord asset,
    void Function(AssetRecord, UploadPhase, int) report,
  ) async {
    vault.markUploading(asset.id);
    report(asset, UploadPhase.started, 0);
    final bytes = await vault.readAsset(asset.id);
    final intent = await transport.postJson('/v1/receipts/upload-intents', {
      'receiptId': asset.ownerId,
      'assetId': asset.id,
      'kind': asset.kind.name,
      'contentType': asset.contentType,
      'sizeBytes': asset.sizeBytes,
      'sha256': asset.sha256,
    });
    final url = Uri.parse(intent['uploadUrl'] as String);
    final headers = (intent['headers'] as Map? ?? const {})
        .cast<String, Object?>()
        .map((k, v) => MapEntry(k, '$v'));
    await transport.send(() async {
      final request = http.StreamedRequest('PUT', url)
        ..headers.addAll(headers)
        ..contentLength = bytes.length;
      unawaited(_stream(request, bytes, asset, report));
      return request;
    });
    await transport.postJson('/v1/receipts/${asset.ownerId}/complete', {
      'assetId': asset.id,
    });
    vault.markUploaded(asset.id, cloudConfirmed: true);
  }

  Future<void> _stream(
    http.StreamedRequest request,
    Uint8List bytes,
    AssetRecord asset,
    void Function(AssetRecord, UploadPhase, int) report,
  ) async {
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = offset + chunkSize > bytes.length
          ? bytes.length
          : offset + chunkSize;
      request.sink.add(Uint8List.sublistView(bytes, offset, end));
      report(asset, UploadPhase.sending, end);
      await Future<void>.delayed(Duration.zero);
    }
    await request.sink.close();
  }

  /// Fetches the cloud copy of an asset that is remote or evicted and
  /// stores it encrypted after verifying its checksum.
  Future<AssetRecord> download(String assetId) async {
    final asset = vault.asset(assetId);
    if (asset == null) throw StateError('No asset $assetId');
    if (asset.localState == AssetLocalState.present) return asset;
    final link = await transport.send(
      () async => http.Request(
        'GET',
        transport.resolve(
          '/v1/receipts/${asset.ownerId}/assets/$assetId/download',
        ),
      )..headers.addAll(await transport.headers()),
      acceptStatus: (s) => s == 404 || s == 409,
    );
    if (link.statusCode != 200) throw AssetNotYetAvailableException(assetId);
    final json = (jsonDecode(link.body) as Map).cast<String, Object?>();
    final url = Uri.parse((json['downloadUrl'] ?? json['url']) as String);
    final response = await transport.send(() async => http.Request('GET', url));
    return vault.storeDownloaded(assetId, response.bodyBytes);
  }
}
