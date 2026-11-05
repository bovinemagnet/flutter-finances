// Checks the PDFium libraries a build downloaded against pinned checksums.
//
// The pdfium_dart package downloads them while building, on Android, Linux and
// Windows, and checks nothing. Its build hook cannot be told a checksum, so this
// runs after the build and fails it before anything is published.
//
// The values are SHA-256 of each library as the hook extracts it. To pin a new
// release after upgrading pdfrx_engine, take the archives from
// bblanchon/pdfium-binaries, check them against that release's signed
// pdfium-attestation.json with `gh attestation verify`, and hash the library in
// each one.
//
//   cd apps/finance_app && dart run tool/verify_pdfium.dart
import 'dart:io';

import 'package:crypto/crypto.dart';

const pinnedRelease = 'chromium_8125';

const pinnedChecksums = {
  'android-arm/libpdfium.so':
      '03bd9d13060401fe4e40625b935d1a8281edac2a4788e98994df1d8a82e9f577',
  'android-arm64/libpdfium.so':
      'de19db1c0fb33579bca6ace903af7ccb9d03ad1d3f6c5202970d8d79d7538303',
  'android-x64/libpdfium.so':
      '5f7e47f76b5c11107f6b451690b97f78f576ab3552441603d8d52b374e6ac33a',
  'android-x86/libpdfium.so':
      '95e6a4bb524407e45a774dd9a7e8d2e4e24daac91c64aa9616929bfaa1395ce8',
  'linux-x64/libpdfium.so':
      '1c251efce460d67437a4c76d4be9033ae2f17bf5603f5bff1af10209b94ca723',
  'linux-arm64/libpdfium.so':
      '8cdc437dce84a6493b9ec6c4f5ad9ff2c299e505acfd7b0ad38cb440805b2c70',
  'win-x64/pdfium.dll':
      '4b0dec92555d69437bef0df37be630181ab3e83a6823ca264ede355a4f2ef994',
  'win-arm64/pdfium.dll':
      '61b3500520d2f7ec2f8074851ba941b1470e85b8849e6efe5966ef2ce676c1f3',
  'mac-arm64/libpdfium.dylib':
      'a45c44645523968525c710462691dd974f4efb1013ce1c249919a0939cfb373a',
  'mac-x64/libpdfium.dylib':
      'a9f428a16f46bab89646c8724b348e01c3fe707e3126d9356026cd876a74aecb',
};

/// Where the build hook keeps what it downloaded, found by looking upwards
/// because a pub workspace keeps `.dart_tool` at its root.
Directory findPdfiumBuild(Directory from) {
  const inside = '.dart_tool/hooks_runner/shared/pdfium_dart/build';
  for (Directory at = from.absolute; ; at = at.parent) {
    final candidate = Directory('${at.path}/$inside');
    if (candidate.existsSync()) return candidate;
    if (at.parent.path == at.path) return Directory('${from.path}/$inside');
  }
}

String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

/// Everything wrong with the libraries under [build]. Finding nothing at all is
/// a problem too: it would mean the plugin moved them and nothing was checked.
List<String> pdfiumProblems(
  Directory build, {
  String release = pinnedRelease,
  Map<String, String> checksums = pinnedChecksums,
}) {
  const nothing = 'Found no PDFium libraries to check';
  if (!build.existsSync()) return ['$nothing in ${build.path}.'];
  final problems = <String>[];
  var checked = 0;
  for (final folder in build.listSync().whereType<Directory>()) {
    if (!_name(folder).startsWith('chromium_')) continue;
    if (_name(folder) != release) {
      problems.add(
        'PDFium ${_name(folder)} has no pinned checksums; this checks '
        '$release. See tool/verify_pdfium.dart for how to pin one.',
      );
      continue;
    }
    for (final target in folder.listSync().whereType<Directory>()) {
      for (final library in target.listSync().whereType<File>()) {
        checked++;
        final key = '${_name(target)}/${_name(library)}';
        final expected = checksums[key];
        final actual = sha256.convert(library.readAsBytesSync()).toString();
        if (expected == null) {
          problems.add('$key has no pinned checksum.');
        } else if (actual != expected) {
          problems.add('$key does not match: $actual, expected $expected.');
        }
      }
    }
  }
  if (checked == 0 && problems.isEmpty) {
    problems.add('$nothing in ${build.path}.');
  }
  return problems;
}

void main() {
  final build = findPdfiumBuild(Directory.current);
  final problems = pdfiumProblems(build);
  if (problems.isEmpty) {
    stdout.writeln('PDFium libraries match their pinned checksums.');
    return;
  }
  problems.forEach(stderr.writeln);
  exitCode = 1;
}
