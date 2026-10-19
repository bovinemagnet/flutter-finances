import 'dart:io';

import 'package:flutter/foundation.dart';

/// What the current device can do. This is the only place that inspects the
/// platform; finance code asks for capabilities, never for an OS (section 10).
@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.documentScanner,
    required this.cameraCapture,
    required this.onDeviceOcr,
    required this.shareTarget,
    required this.dragAndDrop,
    required this.paste,
    required this.fileCapture,
    required this.backgroundWork,
    required this.platformKeyStore,
    required this.isDesktop,
  });

  factory PlatformCapabilities.forPlatform(
    TargetPlatform platform, {
    List<String> desktopOcrLanguages = const [],
  }) {
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    return PlatformCapabilities(
      documentScanner: mobile,
      cameraCapture: mobile,
      onDeviceOcr: mobile || desktopOcrLanguages.contains('eng'),
      shareTarget: mobile,
      dragAndDrop: !mobile,
      paste: true,
      fileCapture: true,
      backgroundWork: mobile,
      // Linux availability depends on a Secret Service provider; the key
      // store adapter checks at runtime and falls back to a password.
      platformKeyStore: true,
      isDesktop: !mobile,
    );
  }

  /// Detects capabilities for the running device, including whether the
  /// optional desktop OCR engine (Tesseract) has English language data.
  static Future<PlatformCapabilities> detect() async {
    final platform = defaultTargetPlatform;
    var languages = const <String>[];
    if (!kIsWeb &&
        (platform == TargetPlatform.linux ||
            platform == TargetPlatform.macOS ||
            platform == TargetPlatform.windows)) {
      languages = await tesseractLanguages();
    }
    return PlatformCapabilities.forPlatform(
      platform,
      desktopOcrLanguages: languages,
    );
  }

  final bool documentScanner;
  final bool cameraCapture;
  final bool onDeviceOcr;
  final bool shareTarget;
  final bool dragAndDrop;
  final bool paste;
  final bool fileCapture;
  final bool backgroundWork;
  final bool platformKeyStore;
  final bool isDesktop;
}

/// Languages installed for the Tesseract command line engine, or empty when
/// Tesseract is not installed.
Future<List<String>> tesseractLanguages() async {
  try {
    final result = await Process.run('tesseract', ['--list-langs']);
    if (result.exitCode != 0) return const [];
    return (result.stdout as String)
        .split('\n')
        .skip(1)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  } on ProcessException {
    return const [];
  }
}
