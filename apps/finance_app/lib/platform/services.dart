import 'dart:async';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart' show CaptureSource;
import 'package:meta/meta.dart';

export 'package:finance_core/finance_core.dart' show CaptureSource;

/// One page or file handed over by a platform service.
@immutable
class CapturedFile {
  const CapturedFile(
    this.bytes, {
    this.fileName,
    this.source = CaptureSource.fileImport,
  });

  final Uint8List bytes;
  final String? fileName;
  final CaptureSource source;
}

/// Why a capture produced nothing; the interface explains each case (UX 02).
enum CaptureFailure { cancelled, permissionDenied, unavailable, failed }

class CaptureException implements Exception {
  CaptureException(this.failure, [this.detail]);
  final CaptureFailure failure;
  final String? detail;

  @override
  String toString() =>
      'CaptureException($failure${detail == null ? '' : ': $detail'})';
}

/// Captures receipt pages with a camera or native document scanner.
abstract interface class ReceiptScanner {
  /// Whether this scanner can run now (resources installed, hardware present).
  Future<bool> isAvailable();

  /// Returns captured pages, or throws [CaptureException].
  Future<List<CapturedFile>> capture();
}

/// Picks files the user selects; works even without camera or photo access.
abstract interface class FileImporter {
  Future<List<CapturedFile>> pickReceipts();
  Future<CapturedFile?> pickStatement();
  Future<String?> pickBackupPath();
  Future<String?> chooseDirectory();
  Future<String?> chooseSaveLocation(String suggestedName);
}

/// Content shared into the application from other apps.
abstract interface class ShareInbox {
  Future<List<CapturedFile>> takePending();
  Stream<List<CapturedFile>> get incoming;
}

/// A local reminder. Text hides amounts and merchants unless the user opts in
/// (PLAN 04); tapping it opens the app, which then shows the details.
@immutable
class Reminder {
  const Reminder({
    required this.id,
    required this.at,
    required this.title,
    required this.privateBody,
    required this.detailedBody,
    this.showDetails = false,
  });

  final int id;
  final DateTime at;
  final String title;
  final String privateBody;
  final String detailedBody;

  /// Whether the user opted in to amounts and merchants in the text.
  final bool showDetails;
}

abstract interface class Notifications {
  Future<void> initialise();
  Future<void> schedule(Reminder reminder, {required bool showDetails});
  Future<void> cancel(int id);
  Future<void> cancelAll();
}

/// Opportunistic background work. Foreground launch always resumes queued
/// work, so nothing depends on background execution succeeding.
abstract interface class BackgroundScheduler {
  Future<void> schedulePeriodicSync(Duration frequency);
  Future<void> cancelAll();
}

/// Tries a preferred scanner and falls back to a basic one (A05).
///
/// Used when the advanced scanner is missing, its resources are not
/// downloaded (first launch in flight mode), or Play services are absent.
/// Cancellation and denied permission are reported, not retried.
class FallbackReceiptScanner implements ReceiptScanner {
  FallbackReceiptScanner(this.preferred, this.fallback);

  final ReceiptScanner preferred;
  final ReceiptScanner fallback;

  /// True when the most recent capture had to use the fallback.
  bool usedFallback = false;

  @override
  Future<bool> isAvailable() async =>
      await preferred.isAvailable() || await fallback.isAvailable();

  @override
  Future<List<CapturedFile>> capture() async {
    usedFallback = false;
    if (await preferred.isAvailable()) {
      try {
        return await preferred.capture();
      } on CaptureException catch (e) {
        if (e.failure == CaptureFailure.cancelled ||
            e.failure == CaptureFailure.permissionDenied) {
          rethrow;
        }
      }
    }
    usedFallback = true;
    return fallback.capture();
  }
}
