import 'dart:convert';
import 'dart:typed_data';

import 'aead.dart';
import 'hkdf.dart';

/// The random 256-bit key that protects one workspace.
///
/// It is never written in plaintext: it is either held by a platform key
/// store or wrapped with a password-derived key. Purpose keys for the
/// database and each receipt file are derived from it with HKDF-SHA-256.
class DataKey {
  DataKey(Uint8List bytes) : _bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 32) {
      throw ArgumentError.value(bytes.length, 'bytes', 'must be 32 bytes');
    }
  }

  factory DataKey.generate() => DataKey(randomBytes(32));

  final Uint8List _bytes;

  Uint8List get bytes => Uint8List.fromList(_bytes);

  /// A 256-bit key for one [purpose], such as `database` or `asset/<id>`.
  Uint8List derive(String purpose) =>
      hkdfSha256(_bytes, info: utf8.encode('finance_store/v1/$purpose'));

  /// Raw key for SQLite3MultipleCiphers, as hex for `PRAGMA hexkey`.
  String get databaseKeyHex =>
      derive('database').map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Per-file key for a receipt asset.
  Uint8List assetKey(String assetId) => derive('asset/$assetId');
}
