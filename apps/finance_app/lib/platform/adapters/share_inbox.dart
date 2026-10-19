import 'dart:async';
import 'dart:io';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../services.dart';

/// Android share target and iOS share extension handoff.
///
/// On iOS the share extension is a separate target with its own lifecycle; it
/// copies shared files into the App Group container and opens the app, which
/// then reads them here. The extension target must be added in Xcode (see the
/// platform capability documentation).
class PluginShareInbox implements ShareInbox {
  final _sharing = ReceiveSharingIntent.instance;

  Future<List<CapturedFile>> _read(List<SharedMediaFile> shared) async {
    final files = <CapturedFile>[];
    for (final item in shared) {
      if (item.type == SharedMediaType.text ||
          item.type == SharedMediaType.url) {
        continue;
      }
      final file = File(item.path);
      if (await file.exists()) {
        files.add(
          CapturedFile(
            await file.readAsBytes(),
            fileName: item.path.split('/').last,
            source: CaptureSource.shareTarget,
          ),
        );
      }
    }
    return files;
  }

  @override
  Future<List<CapturedFile>> takePending() async {
    final files = await _read(await _sharing.getInitialMedia());
    await _sharing.reset();
    return files;
  }

  @override
  Stream<List<CapturedFile>> get incoming =>
      _sharing.getMediaStream().asyncMap(_read).where((f) => f.isNotEmpty);
}

/// Platforms without a share target expose an empty inbox.
class EmptyShareInbox implements ShareInbox {
  @override
  Future<List<CapturedFile>> takePending() async => const [];

  @override
  Stream<List<CapturedFile>> get incoming => const Stream.empty();
}
