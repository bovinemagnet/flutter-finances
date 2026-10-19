import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

const _nonceLength = 12;
const _tagLength = 16;
final _aes = DartAesGcm.with256bits();
final _random = Random.secure();

class DecryptionException implements Exception {
  DecryptionException(this.message);
  final String message;

  @override
  String toString() => 'DecryptionException: $message';
}

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

/// Encrypts with AES-256-GCM and returns `nonce || ciphertext || tag`.
///
/// A fresh random 96-bit nonce is used unless [nonce] is given; callers that
/// supply a nonce must never reuse it with the same key.
Uint8List sealAesGcm(
  List<int> key,
  List<int> plaintext, {
  List<int> aad = const [],
  List<int>? nonce,
}) {
  final box = _aes.encryptSync(
    plaintext,
    secretKeyData: SecretKeyData(key),
    nonce: nonce ?? randomBytes(_nonceLength),
    aad: aad,
  );
  final out = Uint8List(_nonceLength + box.cipherText.length + _tagLength)
    ..setAll(0, box.nonce)
    ..setAll(_nonceLength, box.cipherText)
    ..setAll(_nonceLength + box.cipherText.length, box.mac.bytes);
  return out;
}

/// Reverses [sealAesGcm]; throws [DecryptionException] when the key, the
/// associated data or the bytes do not authenticate.
Uint8List openAesGcm(
  List<int> key,
  List<int> sealed, {
  List<int> aad = const [],
}) {
  if (sealed.length < _nonceLength + _tagLength) {
    throw DecryptionException('ciphertext too short');
  }
  final bytes = sealed is Uint8List ? sealed : Uint8List.fromList(sealed);
  final box = SecretBox(
    Uint8List.sublistView(bytes, _nonceLength, bytes.length - _tagLength),
    nonce: Uint8List.sublistView(bytes, 0, _nonceLength),
    mac: Mac(Uint8List.sublistView(bytes, bytes.length - _tagLength)),
  );
  try {
    return Uint8List.fromList(
      _aes.decryptSync(box, secretKeyData: SecretKeyData(key), aad: aad),
    );
  } on SecretBoxAuthenticationError {
    throw DecryptionException('authentication failed');
  }
}
