import 'dart:typed_data';

import 'package:finance_app/platform/capabilities.dart';
import 'package:finance_app/platform/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeScanner implements ReceiptScanner {
  _FakeScanner({this.available = true, this.failure});
  final bool available;
  final CaptureFailure? failure;
  int calls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<CapturedFile>> capture() async {
    calls++;
    if (failure != null) throw CaptureException(failure!);
    return [CapturedFile(Uint8List(1), source: CaptureSource.camera)];
  }
}

void main() {
  group('FallbackReceiptScanner', () {
    test('uses the preferred scanner when it works', () async {
      final preferred = _FakeScanner();
      final fallback = _FakeScanner();
      final scanner = FallbackReceiptScanner(preferred, fallback);
      expect(await scanner.capture(), hasLength(1));
      expect(scanner.usedFallback, isFalse);
      expect(fallback.calls, 0);
    });

    test('falls back when scanner resources are missing (A05)', () async {
      final scanner = FallbackReceiptScanner(
        _FakeScanner(failure: CaptureFailure.unavailable),
        _FakeScanner(),
      );
      expect(await scanner.capture(), hasLength(1));
      expect(scanner.usedFallback, isTrue);
    });

    test('falls back when the preferred scanner is not installed', () async {
      final preferred = _FakeScanner(available: false);
      final scanner = FallbackReceiptScanner(preferred, _FakeScanner());
      await scanner.capture();
      expect(preferred.calls, 0);
      expect(scanner.usedFallback, isTrue);
    });

    test(
      'does not retry after the user cancels or denies permission',
      () async {
        for (final failure in [
          CaptureFailure.cancelled,
          CaptureFailure.permissionDenied,
        ]) {
          final fallback = _FakeScanner();
          final scanner = FallbackReceiptScanner(
            _FakeScanner(failure: failure),
            fallback,
          );
          await expectLater(
            scanner.capture(),
            throwsA(isA<CaptureException>()),
          );
          expect(fallback.calls, 0);
        }
      },
    );
  });

  group('PlatformCapabilities', () {
    test('desktop always supports file capture, mobile supports scanning', () {
      final linux = PlatformCapabilities.forPlatform(
        TargetPlatform.linux,
        desktopOcrLanguages: const [],
      );
      expect(linux.fileCapture, isTrue);
      expect(linux.dragAndDrop, isTrue);
      expect(linux.documentScanner, isFalse);
      expect(linux.onDeviceOcr, isFalse);
      expect(linux.shareTarget, isFalse);

      final android = PlatformCapabilities.forPlatform(TargetPlatform.android);
      expect(android.documentScanner, isTrue);
      expect(android.onDeviceOcr, isTrue);
      expect(android.shareTarget, isTrue);
      expect(android.fileCapture, isTrue);
    });

    test('desktop OCR is available only with English language data', () {
      expect(
        PlatformCapabilities.forPlatform(
          TargetPlatform.linux,
          desktopOcrLanguages: const ['eng', 'osd'],
        ).onDeviceOcr,
        isTrue,
      );
      expect(
        PlatformCapabilities.forPlatform(
          TargetPlatform.windows,
          desktopOcrLanguages: const ['afr'],
        ).onDeviceOcr,
        isFalse,
      );
    });
  });
}
