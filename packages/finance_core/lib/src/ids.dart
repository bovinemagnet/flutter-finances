import 'dart:math';

final _random = Random.secure();
int _lastMillis = -1;
int _sequence = 0;

/// Generates a UUIDv7 string that can be created offline on any device.
///
/// The leading 48 bits are the Unix time in milliseconds. Within the same
/// millisecond a 12-bit counter keeps identifiers from one process ordered.
String newId() {
  var millis = DateTime.now().toUtc().millisecondsSinceEpoch;
  if (millis <= _lastMillis) {
    _sequence++;
    if (_sequence > 0xfff) {
      _lastMillis++;
      _sequence = 0;
    }
    millis = _lastMillis;
  } else {
    _lastMillis = millis;
    _sequence = _random.nextInt(0x400);
  }
  final bytes = List<int>.filled(16, 0);
  for (var i = 0; i < 6; i++) {
    bytes[i] = (millis >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = 0x70 | (_sequence >> 8);
  bytes[7] = _sequence & 0xff;
  bytes[8] = 0x80 | _random.nextInt(0x40);
  for (var i = 9; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
