import 'dart:async';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/foundation.dart';

import '../platform/services.dart';
import '../platform/text_recognition.dart';
import 'app_state.dart';
import 'receipt_service.dart';

enum _Result { arrived, refused, failed, gone }

/// Saves captured files as one receipt, as [ReceiptService.capture] does.
typedef ReceiptCapture = Future<Receipt> Function(
  List<CapturedFile> files, {
  String? receiptId,
  DateTime? capturedAt,
});

/// Collects forwarded receipts onto this device. Each is saved through the
/// ordinary capture path and acknowledged only once it is durably saved, so a
/// document is never lost, and collecting it again makes no second receipt.
/// Nothing here posts a transaction; a receipt waits for review like any other.
class InboundMailService {
  InboundMailService({
    required this.state,
    required this.client,
    this.recogniser,
    @visibleForTesting ReceiptCapture? capture,
  }) : _capture = capture ?? state.receipts.capture;

  /// Failed saves or damaged downloads of one document before this run of the
  /// app stops trying it, so a document that cannot arrive is not downloaded at
  /// every sync. It stays waiting on the server, and is tried again the next
  /// time the app starts. A dropped connection does not count.
  static const maxCaptureAttempts = 3;

  /// How long a document can fail to arrive before the user is told. Documents
  /// expire after 30 days, so this leaves time to forward it again.
  static const overdueAfter = Duration(days: 7);

  final AppState state;
  final InboundMailClient client;

  /// Reads images once saved. PDFs cannot be read yet, and asking marks them
  /// for entering by hand, as it does for a PDF imported directly.
  final TextRecogniser? recogniser;

  final ReceiptCapture _capture;
  final _failedCaptures = <String, int>{};
  var _running = false;

  /// Collects whatever is waiting. It never throws, because a failure here must
  /// not affect a sync: anything not acknowledged is tried again next time.
  Future<void> collect() async {
    if (_running) return;
    _running = true;
    try {
      final workspaceId = state.settings.workspaceId;
      var inbox = await client.inbox(workspaceId);
      final results = {
        for (final document in inbox.documents)
          document: await _collectOne(workspaceId, document),
      };
      if (results.containsValue(_Result.refused)) {
        inbox = await client.inbox(workspaceId);
      }
      state.setInboundNotices([
        ...inbox.notices,
        for (final MapEntry(key: document, value: result) in results.entries)
          if (result == _Result.failed && _isOverdue(document))
            _notCollected(document),
      ]);
    } catch (_) {
      // Offline, signed out, or an older server: try again after the next sync.
    } finally {
      _running = false;
    }
  }

  bool _isOverdue(InboundDocument document) =>
      DateTime.now().toUtc().difference(document.receivedAt) >= overdueAfter;

  /// Says a document is not arriving while there is still time to act on it.
  InboundNotice _notCollected(InboundDocument document) => InboundNotice(
    messageId: document.id,
    sender: '',
    receivedAt: document.receivedAt,
    outcome: 'not_collected',
    rejections: [
      InboundRejection(fileName: document.fileName, code: 'NOT_COLLECTED'),
    ],
  );

  Future<_Result> _collectOne(
    String workspaceId,
    InboundDocument document,
  ) async {
    if ((_failedCaptures[document.id] ?? 0) >= maxCaptureAttempts) {
      return _Result.failed;
    }
    try {
      final receiptId = nameBasedId(document.id, 'inbound-receipt');
      final saved = state.receipts.receipt(receiptId);
      if (saved != null) {
        // Already saved, so there is nothing to fetch. The app may have stopped
        // before acknowledging it or reading it.
        await _acknowledge(workspaceId, document);
        _readIfUnread(saved);
        return _Result.arrived;
      }
      final bytes = await client.download(workspaceId, document);
      final Receipt receipt;
      try {
        receipt = await _capture(
          [
            CapturedFile(
              bytes,
              fileName: document.fileName,
              source: CaptureSource.email,
            ),
          ],
          receiptId: receiptId,
          capturedAt: document.receivedAt,
        );
      } on ReceiptRejectedException catch (e) {
        await client.reject(
          workspaceId,
          document.id,
          code: 'REJECTED_ON_DEVICE',
          detail: e.messages.join(' '),
        );
        return _Result.refused;
      } catch (_) {
        _countFailure(document);
        return _Result.failed;
      }
      await _acknowledge(workspaceId, document);
      _readIfUnread(receipt);
      return _Result.arrived;
    } on InboundDocumentGoneException {
      return _Result.gone;
    } on InboundDocumentCorruptException {
      _countFailure(document);
      return _Result.failed;
    } catch (_) {
      // Unreachable for now: the others can still arrive.
      return _Result.failed;
    }
  }

  /// A copy that came from another device is read there, where its document
  /// is. Runs alongside, so slow recognition never holds up other documents.
  void _readIfUnread(Receipt receipt) {
    if (receipt.extractionState == ExtractionState.captured &&
        state.receipts.isHeldHere(receipt.id)) {
      unawaited(_read(receipt));
    }
  }

  void _countFailure(InboundDocument document) =>
      _failedCaptures.update(document.id, (n) => n + 1, ifAbsent: () => 1);

  /// Saved but not acknowledged is safe: the next collection acknowledges it.
  Future<void> _acknowledge(String workspaceId, InboundDocument document) =>
      client.acknowledge(workspaceId, document.id).catchError((Object _) {});

  Future<void> _read(Receipt receipt) async {
    try {
      final recogniser = this.recogniser;
      if (recogniser == null || !await recogniser.isAvailable()) return;
      await state.receipts.extract(receipt.id, recogniser);
    } catch (_) {
      // The receipt is safe; it can be read again or entered by hand.
    }
  }
}
