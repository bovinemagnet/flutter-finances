import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Background sync once built its own client and missed a conflict rule, so
/// the one place that builds a client is what gives every sync the same rules.
void main() {
  test('every sync client the app builds comes from one place', () {
    final builders = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            RegExp(
              r'(?<![A-Za-z_.])SyncClient\(',
            ).hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(builders, ['lib/data/app_sync_client.dart']);
  });
}
