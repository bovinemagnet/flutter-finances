import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'ops.dart';

/// Runs every case in the shared `spec/fixtures` directory. The Java server
/// runs the same files, so both implementations agree on financial rules.
void main() {
  final dir = Directory('${_repoRoot()}/spec/fixtures');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    if (document['schemaVersion'] != 1) {
      throw StateError('Unsupported fixture schema in ${file.path}');
    }
    group(document['area'] as String, () {
      for (final raw in document['cases'] as List<dynamic>) {
        final fixture = raw as Map<String, dynamic>;
        test(fixture['id'] as String, () {
          final op = fixture['op'] as String;
          final handler = fixtureOps[op];
          if (handler == null) fail('No Dart handler for fixture op "$op"');
          handler(
            fixture['input'] as Map<String, dynamic>,
            fixture['expect'] as Map<String, dynamic>,
          );
        });
      }
    });
  }
}

String _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/spec/fixtures/money.json').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('spec/fixtures not found');
    dir = parent;
  }
  return dir.path;
}
