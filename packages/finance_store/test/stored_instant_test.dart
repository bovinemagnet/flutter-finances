import 'dart:math';

import 'package:finance_store/src/store/local_state.dart';
import 'package:test/test.dart';

void main() {
  /// The value, or that it could not be read, so failures can be compared too.
  Object? outcome(DateTime Function(String) parse, String text) {
    try {
      final value = parse(text);
      return (value.microsecondsSinceEpoch, value.isUtc);
    } on FormatException {
      return 'FormatException';
    }
  }

  void same(String text) => expect(
    outcome(parseStoredInstant, text),
    outcome((t) => DateTime.parse(t).toUtc(), text),
    reason: text,
  );

  test('reads what the store writes, exactly as DateTime.parse does', () {
    final random = Random(11);
    for (var i = 0; i < 20000; i++) {
      final instant = DateTime.fromMicrosecondsSinceEpoch(
        // From 1902 to 2037, with micros, millis or whole seconds.
        (random.nextDouble() * 4294967296).toInt() * 1000000 -
            2147483648 * 1000000 +
            switch (i % 3) {
              0 => random.nextInt(1000000),
              1 => random.nextInt(1000) * 1000,
              _ => 0,
            },
        isUtc: true,
      );
      final text = instant.toIso8601String();
      same(text);
      expect(parseStoredInstant(text), instant);
    }
  });

  test('anything else gets the same answer as DateTime.parse', () {
    for (final text in [
      '2026-10-20T10:00:00.000Z',
      '2026-10-20T10:00:00.000000Z',
      '2026-10-20T10:00:00Z',
      '2026-10-20T10:00:00.1Z',
      '2026-10-20T10:00:00.000',
      '2026-10-20T10:00:00.000+10:00',
      '2026-10-20T10:00:00+10:00',
      '2026-10-20 10:00:00.000Z',
      '2026-10-20',
      '20261020T100000Z',
      '2026-02-30T00:00:00.000Z',
      '2026-13-01T00:00:00.000Z',
      '2026-00-01T00:00:00.000Z',
      '2026-01-00T00:00:00.000Z',
      '2026-10-20T24:00:00.000Z',
      '2026-10-20T25:00:00.000Z',
      '2026-10-20T10:60:00.000Z',
      '2026-10-20T10:00:60.000Z',
      '2026-1x-20T10:00:00.000Z',
      '2026-10-20T10:00:00.00xZ',
      '2026-10-20T10:00:00.000z',
      '2026x10-20T10:00:00.000Z',
      '2026-10x20T10:00:00.000Z',
      '2026-10-20x10:00:00.000Z',
      '2026-10-20T10x00:00.000Z',
      '2026-10-20T10:00x00.000Z',
      '2026-10-20T10:00:00x000Z',
      '2026-10-20T10:00:00,000Z',
      '2026-10-20t10:00:00.000Z',
      '2026-00-00T00:00:00.000Z',
      '2026-12-32T23:59:59.999Z',
      '2026-10-20T10:61:00.000Z',
      '2026-10-20T10:00:61.000Z',
      '2026-10-20T24:00:00.000000Z',
      'x026-10-20T10:00:00.000Z',
      '2026-10-20T1x:00:00.000Z',
      '2026-10-20T10:0x:00.000Z',
      '2026-10-20T10:00:0x.000Z',
      '2026-10-20T10:00:00.x00Z',
      '2026-10-20T10:00:00.000x00Z',
      '2026-10-2xT10:00:00.000Z',
      '2026-10-20T10:00:00.000000X',
      '+2026-10-20T10:00:00.000Z',
      '-0001-10-20T10:00:00.000Z',
      '٢٠٢٦-10-20T10:00:00.000Z',
      '',
      'not a date',
    ]) {
      same(text);
    }
  });
}
