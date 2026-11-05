import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/verify_pdfium.dart';

void main() {
  late Directory build;

  setUp(() async => build = await Directory.systemTemp.createTemp('pdfium'));
  tearDown(() => build.delete(recursive: true));

  String hash(String text) => sha256.convert(utf8.encode(text)).toString();

  void library(String path, String contents) {
    File('${build.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  List<String> check() => pdfiumProblems(
    build,
    release: 'chromium_1',
    checksums: {
      'android-arm64/libpdfium.so': hash('good'),
      'win-x64/pdfium.dll': hash('windows'),
    },
  );

  test('accepts what was pinned', () {
    library('chromium_1/android-arm64/libpdfium.so', 'good');
    library('chromium_1/win-x64/pdfium.dll', 'windows');
    expect(check(), isEmpty);
  });

  test('accepts only some of them, since each build gets its own', () {
    library('chromium_1/win-x64/pdfium.dll', 'windows');
    expect(check(), isEmpty);
  });

  test('refuses a library that differs', () {
    library('chromium_1/android-arm64/libpdfium.so', 'tampered');
    expect(check().single, contains('android-arm64/libpdfium.so'));
    expect(check().single, contains('does not match'));
  });

  test('reports every bad library, not only the first', () {
    library('chromium_1/android-arm64/libpdfium.so', 'tampered');
    library('chromium_1/win-x64/pdfium.dll', 'tampered');
    expect(check(), hasLength(2));
  });

  test('refuses a library with no checksum', () {
    library('chromium_1/linux-x64/libpdfium.so', 'anything');
    expect(check().single, contains('no pinned checksum'));
  });

  test('refuses a newer PDFium until it has been pinned', () {
    library('chromium_1/win-x64/pdfium.dll', 'windows');
    library('chromium_2/win-x64/pdfium.dll', 'windows');
    expect(check().single, contains('chromium_2'));
  });

  test('refuses to pass when it found nothing to check', () {
    expect(check().single, contains('no PDFium'));
  });

  test('refuses to pass when the folder is not there', () {
    final problems = pdfiumProblems(
      Directory('${build.path}/missing'),
      release: 'chromium_1',
      checksums: const {},
    );
    expect(problems.single, contains('no PDFium'));
  });

  test('ignores anything that is not a library folder', () {
    File('${build.path}/stray.txt').writeAsStringSync('hello');
    library('chromium_1/win-x64/pdfium.dll', 'windows');
    expect(check(), isEmpty);
  });

  test('ignores the hook\'s own build folders', () {
    library('cd8d4b1993/out/libpdfrx_pdfium_gate.so', 'gate');
    library('chromium_1/win-x64/pdfium.dll', 'windows');
    expect(check(), isEmpty);
  });

  test('finds the folder from inside the workspace', () {
    final root = Directory('${build.path}/repo');
    final expected = Directory(
      '${root.path}/.dart_tool/hooks_runner/shared/pdfium_dart/build',
    )..createSync(recursive: true);
    final app = Directory('${root.path}/apps/finance_app')
      ..createSync(recursive: true);
    expect(
      Directory(findPdfiumBuild(app).path).resolveSymbolicLinksSync(),
      expected.resolveSymbolicLinksSync(),
    );
  });

  group('the pinned checksums', () {
    test('cover every platform this app is built for', () {
      expect(
        pinnedChecksums.keys,
        containsAll([
          'android-arm/libpdfium.so',
          'android-arm64/libpdfium.so',
          'android-x64/libpdfium.so',
          'linux-x64/libpdfium.so',
          'win-x64/pdfium.dll',
        ]),
      );
    });

    test('are all whole SHA-256 values', () {
      for (final checksum in pinnedChecksums.values) {
        expect(checksum, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });
  });
}
