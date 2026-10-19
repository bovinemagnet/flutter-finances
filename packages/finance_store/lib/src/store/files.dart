import 'dart:io';

/// Writes [bytes] to [path] durably: a temporary sibling is written and
/// flushed to disk, then atomically renamed over the target.
///
/// Directory entries cannot be synced from Dart; the rename is atomic on
/// every supported file system, so a crash leaves either the old or the new
/// file, never a partial one.
void writeFileAtomically(String path, List<int> bytes) {
  final temp = File('$path.tmp');
  final raf = temp.openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(bytes);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  temp.renameSync(path);
}
