import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release builds shrink the code and debug builds do not, so losing these
/// rules passes every test and every debug run, then stops all text recognition
/// on Android: ML Kit fails at run time on every photo and scanned PDF.
void main() {
  test('release builds keep the classes ML Kit finds by name', () {
    final rules = File('android/app/proguard-rules.pro').readAsLinesSync();
    expect(rules, contains('-keep class com.google.mlkit.** { *; }'));
    expect(
      rules,
      contains('-keep class com.google.android.gms.internal.mlkit_** { *; }'),
    );
  });
}
