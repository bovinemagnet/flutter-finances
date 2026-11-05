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
/// always deleted afterwards.
class ShareFileExporter implements FileExporter {
  ShareFileExporter({
    required this.temporaryDirectory,
    Future<bool> Function(String path)? share,
  }) : _share = share ?? _shareWithSheet;

  final Directory temporaryDirectory;
  final Future<bool> Function(String path) _share;

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
    await temporaryDirectory.create(recursive: true);
    final working = await temporaryDirectory.createTemp('export');
    try {
      final path = await prepare(working);
      return await _share(path) ? ExportOutcome.saved : ExportOutcome.cancelled;
    } finally {
      if (working.existsSync()) await working.delete(recursive: true);
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
