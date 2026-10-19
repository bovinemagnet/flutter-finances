import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart' show newId;
import 'package:meta/meta.dart';

import 'aead.dart';
import 'data_key.dart';
import 'kdf.dart';

/// A platform key store (Keychain, Android Keystore, Windows DPAPI or a
/// Secret Service on Linux), implemented by the application.
///
/// The platform protects what it stores; biometrics may gate access to an
/// entry but are never the encryption scheme (SEC 02).
abstract interface class SecureKeyStore {
  /// Whether a suitable protected store exists. On Linux this detects a
  /// Secret Service; when it is missing the password fallback is required.
  Future<bool> isAvailable();

  Future<Uint8List?> read(String name);

  Future<void> write(String name, Uint8List material);

  Future<void> delete(String name);
}

class PasswordRequiredException implements Exception {
  @override
  String toString() =>
      'No platform key store is available; a password is required';
}

class KeyStoreUnavailableException implements Exception {
  KeyStoreUnavailableException([this.detail]);
  final String? detail;

  @override
  String toString() =>
      'Platform key store unavailable${detail == null ? '' : ': $detail'}';
}

class WrongPasswordException implements Exception {
  @override
  String toString() => 'The password does not unlock this workspace';
}

class KeyProtectionMismatchException implements Exception {
  KeyProtectionMismatchException(this.expected);
  final String expected;

  @override
  String toString() => 'This workspace is protected by $expected';
}

/// A data key together with the non-secret description needed to unlock
/// it again, which is stored in the workspace descriptor.
class ProtectedKey {
  ProtectedKey(this.key, this.descriptor);
  final DataKey key;
  final Map<String, Object?> descriptor;
}

/// How the workspace data key is protected at rest (SEC 02).
sealed class KeyProtection {
  const KeyProtection();

  factory KeyProtection.platform(SecureKeyStore store) = PlatformKeyProtection;

  factory KeyProtection.password(String password, {Argon2idParameters kdf}) =
      PasswordKeyProtection;

  /// Prefers the platform store and falls back to [password] when it is
  /// unavailable. Without either, throws [PasswordRequiredException] rather
  /// than ever writing a plaintext key.
  static Future<KeyProtection> select({
    SecureKeyStore? platformStore,
    String? password,
    Argon2idParameters kdf = Argon2idParameters.standard,
  }) async {
    if (platformStore != null && await platformStore.isAvailable()) {
      return PlatformKeyProtection(platformStore);
    }
    if (password == null || password.isEmpty) {
      throw PasswordRequiredException();
    }
    return PasswordKeyProtection(password, kdf: kdf);
  }

  /// Generates and protects a new random data key.
  Future<ProtectedKey> create();

  /// Recovers the data key described by [descriptor].
  Future<DataKey> unlock(Map<String, Object?> descriptor);
}

/// Keeps the data key in the platform key store under a random entry name.
final class PlatformKeyProtection extends KeyProtection {
  const PlatformKeyProtection(this.store);
  final SecureKeyStore store;

  @override
  Future<ProtectedKey> create() async {
    if (!await store.isAvailable()) throw KeyStoreUnavailableException();
    final key = DataKey.generate();
    final entry = 'finance_store/data-key/${newId()}';
    await store.write(entry, key.bytes);
    return ProtectedKey(key, {'protection': 'platform', 'entry': entry});
  }

  @override
  Future<DataKey> unlock(Map<String, Object?> descriptor) async {
    if (descriptor['protection'] != 'platform') {
      throw KeyProtectionMismatchException('${descriptor['protection']}');
    }
    if (!await store.isAvailable()) throw KeyStoreUnavailableException();
    final material = await store.read(descriptor['entry'] as String);
    if (material == null) {
      throw KeyStoreUnavailableException('key entry missing');
    }
    return DataKey(material);
  }
}

/// Wraps the data key with a key derived from a user secret (the Linux
/// fallback, and an option on every platform).
final class PasswordKeyProtection extends KeyProtection {
  const PasswordKeyProtection(
    this.password, {
    this.kdf = Argon2idParameters.standard,
  });

  final String password;
  final Argon2idParameters kdf;

  @override
  Future<ProtectedKey> create() async {
    final key = DataKey.generate();
    final envelope = await PasswordWrappedKey.wrap(
      key,
      password,
      parameters: kdf,
    );
    return ProtectedKey(key, {
      'protection': 'password',
      'envelope': envelope.toJson(),
    });
  }

  @override
  Future<DataKey> unlock(Map<String, Object?> descriptor) {
    if (descriptor['protection'] != 'password') {
      throw KeyProtectionMismatchException('${descriptor['protection']}');
    }
    return PasswordWrappedKey.fromJson(
      (descriptor['envelope'] as Map).cast<String, Object?>(),
    ).unwrap(password);
  }
}

/// A data key encrypted with AES-256-GCM under an Argon2id-derived key.
///
/// The salt is 16 random bytes; the associated data binds the envelope
/// version so a downgraded envelope does not authenticate.
@immutable
class PasswordWrappedKey {
  const PasswordWrappedKey(this.parameters, this.salt, this.sealed);

  factory PasswordWrappedKey.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw FormatException('Unsupported key envelope', json['version']);
    }
    return PasswordWrappedKey(
      Argon2idParameters.fromJson((json['kdf'] as Map).cast<String, Object?>()),
      base64Decode(json['salt'] as String),
      base64Decode(json['wrappedKey'] as String),
    );
  }

  static final _aad = utf8.encode('finance_store/key-envelope/v1');

  final Argon2idParameters parameters;
  final Uint8List salt;
  final Uint8List sealed;

  static Future<PasswordWrappedKey> wrap(
    DataKey key,
    String password, {
    Argon2idParameters parameters = Argon2idParameters.standard,
  }) async {
    final salt = randomBytes(16);
    final kek = await parameters.deriveKey(password, salt);
    return PasswordWrappedKey(
      parameters,
      salt,
      sealAesGcm(kek, key.bytes, aad: _aad),
    );
  }

  Future<DataKey> unwrap(String password) async {
    final kek = await parameters.deriveKey(password, salt);
    try {
      return DataKey(openAesGcm(kek, sealed, aad: _aad));
    } on DecryptionException {
      throw WrongPasswordException();
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'cipher': 'AES-256-GCM',
    'kdf': parameters.toJson(),
    'salt': base64Encode(salt),
    'wrappedKey': base64Encode(sealed),
  };
}

/// Rewraps a password-protected key descriptor under [newPassword].
///
/// The data key itself does not change, so the database and receipt files
/// need no re-encryption.
Future<Map<String, Object?>> changePassword(
  Map<String, Object?> descriptor,
  String oldPassword,
  String newPassword, {
  Argon2idParameters kdf = Argon2idParameters.standard,
}) async {
  final key = await PasswordKeyProtection(oldPassword).unlock(descriptor);
  final envelope = await PasswordWrappedKey.wrap(
    key,
    newPassword,
    parameters: kdf,
  );
  return {'protection': 'password', 'envelope': envelope.toJson()};
}
