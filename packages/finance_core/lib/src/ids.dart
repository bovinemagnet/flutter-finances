import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

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
  return _format(bytes);
}

/// The name-based (version 5, SHA-1) UUID of [name] within the [namespace]
/// UUID (RFC 9562). Every device derives the same identifier, so records
/// that belong to another record, such as a journal's annotation, can be
/// addressed offline without sharing that record's identifier.
String nameBasedId(String namespace, String name) {
  final hex = namespace.replaceAll('-', '');
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
    throw FormatException('Namespace is not a UUID', namespace);
  }
  final digest = sha1.convert([
    for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ...utf8.encode(name),
  ]);
  final bytes = digest.bytes.sublist(0, 16);
  bytes[6] = 0x50 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  return _format(bytes);
}

String _format(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
