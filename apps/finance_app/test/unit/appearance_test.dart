import 'dart:io';

import 'package:finance_app/app/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('appearance');
    file = File('${dir.path}/appearance.json');
  });
  tearDown(() => dir.delete(recursive: true));

  test('follows the system until a choice is saved', () async {
    final appearance = await Appearance.load(file);
    expect(appearance.value, ThemeMode.system);
    expect(file.existsSync(), isFalse);
  });

  test('a chosen mode is kept for the next start', () async {
    final appearance = await Appearance.load(file);
    await appearance.setMode(ThemeMode.dark);
    expect(appearance.value, ThemeMode.dark);
    expect((await Appearance.load(file)).value, ThemeMode.dark);
  });

  test('an unreadable file falls back to the system setting', () async {
    await file.writeAsString('not json');
    expect((await Appearance.load(file)).value, ThemeMode.system);
    await file.writeAsString('{"themeMode": "sepia"}');
    expect((await Appearance.load(file)).value, ThemeMode.system);
  });
}
