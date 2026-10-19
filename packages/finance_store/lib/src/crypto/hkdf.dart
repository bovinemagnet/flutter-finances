import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF with HMAC-SHA-256 (RFC 5869).
///
/// Used to derive independent purpose keys (database, per-file) from one
/// random data key, so that compromising one derived key reveals nothing
/// about the others.
Uint8List hkdfSha256(
  List<int> ikm, {
  List<int> salt = const [],
  required List<int> info,
  int length = 32,
}) {
  if (length <= 0 || length > 255 * 32) {
    throw ArgumentError.value(length, 'length');
  }
  final prk = Hmac(
    sha256,
    salt.isEmpty ? List.filled(32, 0) : salt,
  ).convert(ikm).bytes;
  final output = BytesBuilder(copy: false);
  var previous = <int>[];
  for (var counter = 1; output.length < length; counter++) {
    previous = Hmac(sha256, prk).convert([...previous, ...info, counter]).bytes;
    output.add(previous);
  }
  return Uint8List.fromList(output.takeBytes().sublist(0, length));
}
