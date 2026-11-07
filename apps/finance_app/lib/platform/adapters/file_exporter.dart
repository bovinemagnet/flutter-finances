import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:share_plus/share_plus.dart';

import '../services.dart';

/// Saves through the save and folder dialogs a desktop has.
class DesktopFileExporter implements FileExporter {
  DesktopFileExporter({
    required this.chooseSaveLocation,
    required this.chooseDirectory,
  });

  final Future<String?> Function(String suggestedName) chooseSaveLocation;
  final Future<String?> Function() chooseDirectory;

  @override
  Future<ExportOutcome> exportFile(
    String name,
    Future<void> Function(File file) write,
  ) async {
    final path = await chooseSaveLocation(name);
    if (path == null) return ExportOutcome.cancelled;
    await write(File(path));
    return ExportOutcome.saved;
  }

  @override
  Future<ExportOutcome> exportFolder(
    String name,
    Future<void> Function(Directory folder) write,
  ) async {
    final parent = await chooseDirectory();
    if (parent == null) return ExportOutcome.cancelled;
    var folder = Directory('$parent/$name');
    for (var n = 2; folder.existsSync(); n++) {
      folder = Directory('$parent/$name-$n');
    }
    await folder.create(recursive: true);
    await write(folder);
    return ExportOutcome.saved;
  }
}

/// Saves through the share sheet, the only way a phone offers: iOS and Android
/// have no save dialog an app can open, and iOS has no folder dialog. A folder
/// is shared as one zip. The temporary copy holds unencrypted receipts, so it is
/// deleted afterwards, or by [clearLeftovers] at the next start if the app was
/// killed during the share.
///
/// On Android the share plugin keeps a copy of its own in the cache, which it
/// only clears on the next share. The app that received the file may not have
/// read it when the sheet closes, so that copy goes after [clearAfter], or at
/// once if nothing was shared, and [clearLeftovers] clears one left by an
/// earlier run.
class ShareFileExporter implements FileExporter {
  ShareFileExporter({
    required this.temporaryDirectory,
    Future<bool> Function(String path)? share,
    this.clearAfter = const Duration(minutes: 10),
  }) : _share = share ?? _shareWithSheet;

  final Directory temporaryDirectory;
  final Future<bool> Function(String path) _share;
  final Duration clearAfter;
  Timer? _clearing;

  /// Starts every working folder's name, so one left behind can be recognised.
  static const _workingPrefix = 'finance-export-';

  /// For start-up, when no export can be running: another export's working
  /// folder must not be taken from under it.
  Future<void> clearLeftovers() async {
    await _clearPluginCopy();
    try {
      if (!temporaryDirectory.existsSync()) return;
      for (final entry in temporaryDirectory.listSync()) {
        if (entry is Directory &&
            entry.path.split('/').last.startsWith(_workingPrefix)) {
          await entry.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // As below: this is tried again at the next start.
    }
  }

  Future<void> _clearPluginCopy() async {
    final copies = Directory('${temporaryDirectory.path}/share_plus');
    try {
      if (copies.existsSync()) await copies.delete(recursive: true);
    } on FileSystemException {
      // Cache that cannot be cleared must not stop the app; the plugin and
      // Android both clear it later.
    }
  }

  static Future<bool> _shareWithSheet(String path) async {
    final view = ui.PlatformDispatcher.instance.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        // An iPad places the sheet here, and refuses to show it without one.
        sharePositionOrigin: ui.Rect.fromCenter(
          center: size.center(ui.Offset.zero),
          width: 1,
          height: 1,
        ),
      ),
    );
    return result.status != ShareResultStatus.dismissed;
  }

  Future<ExportOutcome> _withTemporary(
    Future<String> Function(Directory working) prepare,
  ) async {
    _clearing?.cancel();
    await temporaryDirectory.create(recursive: true);
    final working = await temporaryDirectory.createTemp(_workingPrefix);
    var shared = false;
    try {
      final path = await prepare(working);
      shared = await _share(path);
      return shared ? ExportOutcome.saved : ExportOutcome.cancelled;
    } finally {
      if (working.existsSync()) await working.delete(recursive: true);
      if (shared) {
        _clearing = Timer(clearAfter, _clearPluginCopy);
      } else {
        await _clearPluginCopy();
      }
    }
  }

  @override
  Future<ExportOutcome> exportFile(
    String name,
    Future<void> Function(File file) write,
  ) => _withTemporary((working) async {
    final file = File('${working.path}/$name');
    await write(file);
    return file.path;
  });

  @override
  Future<ExportOutcome> exportFolder(
    String name,
    Future<void> Function(Directory folder) write,
  ) => _withTemporary((working) async {
    final folder = Directory('${working.path}/contents');
    await folder.create();
    await write(folder);
    final zip = '${working.path}/$name.zip';
    final encoder = ZipFileEncoder()..create(zip);
    await encoder.addDirectory(folder, includeDirName: false);
    await encoder.close();
    return zip;
  });
}
