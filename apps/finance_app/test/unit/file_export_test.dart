import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:finance_app/platform/adapters/file_exporter.dart';
import 'package:finance_app/platform/adapters/file_importer.dart';
import 'package:finance_app/platform/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('export'));
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('on a phone, through the share sheet', () {
    final shared = <String>[];
    var kept = true;
    final contents = <String, List<int>>{};

    ShareFileExporter exporter() => ShareFileExporter(
      temporaryDirectory: temp,
      share: (path) async {
        shared.add(path);
        contents[path] = File(path).readAsBytesSync();
        return kept;
      },
    );

    setUp(() {
      shared.clear();
      contents.clear();
      kept = true;
    });

    test('offers a file under the name it was given', () async {
      final outcome = await exporter().exportFile(
        'transactions.csv',
        (file) => file.writeAsString('a,b'),
      );
      expect(outcome, ExportOutcome.saved);
      expect(shared.single.endsWith('/transactions.csv'), isTrue);
      expect(String.fromCharCodes(contents[shared.single]!), 'a,b');
    });

    test('offers a folder as one zip of the same name', () async {
      final outcome = await exporter().exportFolder('finance-FY2025-26', (
        folder,
      ) async {
        await File('${folder.path}/summary.csv').writeAsString('totals');
        await Directory('${folder.path}/receipts').create();
        await File('${folder.path}/receipts/one.pdf').writeAsString('pdf');
      });
      expect(outcome, ExportOutcome.saved);
      expect(shared.single.endsWith('/finance-FY2025-26.zip'), isTrue);
      final archive = ZipDecoder().decodeBytes(contents[shared.single]!);
      final names = [
        for (final f in archive.files)
          if (f.isFile) f.name,
      ];
      expect(names, containsAll(['summary.csv', 'receipts/one.pdf']));
      expect(
        String.fromCharCodes(
          archive.files.firstWhere((f) => f.name == 'summary.csv').content,
        ),
        'totals',
      );
    });

    test('says when the person backed out', () async {
      kept = false;
      final outcome = await exporter().exportFile(
        'a.csv',
        (file) => file.writeAsString('a'),
      );
      expect(outcome, ExportOutcome.cancelled);
    });

    group('leaves nothing behind, since receipts are not encrypted here', () {
      void expectEmpty() => expect(temp.listSync(), isEmpty);

      test('after sharing a file', () async {
        await exporter().exportFile('a.csv', (f) => f.writeAsString('a'));
        expectEmpty();
      });

      test('after sharing a folder', () async {
        await exporter().exportFolder('pack', (folder) async {
          await File('${folder.path}/a.csv').writeAsString('a');
        });
        expectEmpty();
      });

      test('after backing out', () async {
        kept = false;
        await exporter().exportFolder('pack', (folder) async {
          await File('${folder.path}/a.csv').writeAsString('a');
        });
        expectEmpty();
      });

      test('when writing fails', () async {
        await expectLater(
          exporter().exportFile('a.csv', (file) async {
            await file.writeAsString('partial');
            throw const FileSystemException('disk full');
          }),
          throwsA(isA<FileSystemException>()),
        );
        expect(shared, isEmpty);
        expectEmpty();
      });

      test('when sharing fails', () async {
        final failing = ShareFileExporter(
          temporaryDirectory: temp,
          share: (_) async => throw const FileSystemException('no sheet'),
        );
        await expectLater(
          failing.exportFile('a.csv', (f) => f.writeAsString('a')),
          throwsA(isA<FileSystemException>()),
        );
        expectEmpty();
      });
    });
  });

  group('the copy Android keeps of a shared file', () {
    late Directory copies;

    setUp(() => copies = Directory('${temp.path}/share_plus'));

    Future<bool> pluginCopies(String path) async {
      await copies.create();
      await File('${copies.path}/receipts.zip').writeAsString('receipts');
      return true;
    }

    Future<void> waitUntilGone() async {
      for (var i = 0; i < 200 && copies.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<ExportOutcome> shareWith(ShareFileExporter exporter) =>
        exporter.exportFile('a.csv', (f) => f.writeAsString('a'));

    test('stays for now, since the other app may still be reading', () async {
      final exporter = ShareFileExporter(
        temporaryDirectory: temp,
        share: pluginCopies,
      );
      await shareWith(exporter);
      expect(copies.existsSync(), isTrue);
    });

    test('goes after a while', () async {
      final exporter = ShareFileExporter(
        temporaryDirectory: temp,
        share: pluginCopies,
        clearAfter: const Duration(milliseconds: 1),
      );
      await shareWith(exporter);
      await waitUntilGone();
      expect(copies.existsSync(), isFalse);
    });

    test('goes at once when nothing was shared', () async {
      final exporter = ShareFileExporter(
        temporaryDirectory: temp,
        share: (path) async {
          await pluginCopies(path);
          return false;
        },
      );
      await shareWith(exporter);
      expect(copies.existsSync(), isFalse);
    });

    test('goes at once when sharing fails', () async {
      final exporter = ShareFileExporter(
        temporaryDirectory: temp,
        share: (path) async {
          await pluginCopies(path);
          throw const FileSystemException('no sheet');
        },
      );
      await expectLater(shareWith(exporter), throwsA(anything));
      expect(copies.existsSync(), isFalse);
    });

    test('a later share is not cleared by the earlier timer', () async {
      var shares = 0;
      final exporter = ShareFileExporter(
        temporaryDirectory: temp,
        share: (path) async {
          await pluginCopies(path);
          shares++;
          return true;
        },
        clearAfter: const Duration(milliseconds: 60),
      );
      await shareWith(exporter);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await exporter.exportFile('b.csv', (f) async {
        // The earlier timer would have fired during this share.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await f.writeAsString('b');
        expect(copies.existsSync(), isTrue);
      });
      expect(shares, 2);
    });

    test('left by an earlier run is cleared on request', () async {
      await pluginCopies('');
      final exporter = ShareFileExporter(temporaryDirectory: temp);
      await exporter.clearLeftovers();
      expect(copies.existsSync(), isFalse);
    });

    test('clearing is fine when there is nothing there', () async {
      final exporter = ShareFileExporter(temporaryDirectory: temp);
      await exporter.clearLeftovers();
      expect(temp.listSync(), isEmpty);
    });
  });

  group('on a desktop, through a dialog', () {
    test('saves a file where the person chose', () async {
      final target = '${temp.path}/chosen.csv';
      final exporter = DesktopFileExporter(
        chooseSaveLocation: (name) async {
          expect(name, 'a.csv');
          return target;
        },
        chooseDirectory: () async => null,
      );
      final outcome = await exporter.exportFile(
        'a.csv',
        (f) => f.writeAsString('a'),
      );
      expect(outcome, ExportOutcome.saved);
      expect(File(target).readAsStringSync(), 'a');
    });

    test('saves a folder inside the one chosen', () async {
      final exporter = DesktopFileExporter(
        chooseSaveLocation: (_) async => null,
        chooseDirectory: () async => temp.path,
      );
      await exporter.exportFolder('pack', (folder) async {
        await File('${folder.path}/a.csv').writeAsString('a');
      });
      expect(File('${temp.path}/pack/a.csv').readAsStringSync(), 'a');
    });

    test('does not write over an earlier folder', () async {
      final exporter = DesktopFileExporter(
        chooseSaveLocation: (_) async => null,
        chooseDirectory: () async => temp.path,
      );
      for (final text in ['first', 'second']) {
        await exporter.exportFolder('pack', (folder) async {
          await File('${folder.path}/a.csv').writeAsString(text);
        });
      }
      expect(File('${temp.path}/pack/a.csv').readAsStringSync(), 'first');
      expect(File('${temp.path}/pack-2/a.csv').readAsStringSync(), 'second');
    });

    test('writes nothing when the dialog is cancelled', () async {
      var wrote = false;
      final exporter = DesktopFileExporter(
        chooseSaveLocation: (_) async => null,
        chooseDirectory: () async => null,
      );
      expect(
        await exporter.exportFile('a.csv', (_) async => wrote = true),
        ExportOutcome.cancelled,
      );
      expect(
        await exporter.exportFolder('p', (_) async => wrote = true),
        ExportOutcome.cancelled,
      );
      expect(wrote, isFalse);
    });
  });

  group('a backup can be chosen when restoring', () {
    const XTypeGroup group = backupFileTypes;

    test('on iOS, which needs a type identifier or it throws', () {
      expect(group.uniformTypeIdentifiers, isNotEmpty);
    });

    test('on Android, which does not know this file extension', () {
      expect(group.mimeTypes, contains('*/*'));
    });

    test('on a desktop, showing only backups', () {
      expect(group.extensions, ['fsbackup']);
    });
  });
}
