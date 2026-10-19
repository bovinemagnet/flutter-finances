import 'dart:convert';

import 'package:finance_store/finance_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The operating system key store: Keychain on Apple platforms, Keystore on
/// Android, Credential Locker on Windows and the Secret Service on Linux.
///
/// [isAvailable] performs a write and read round trip, because a Linux
/// desktop without a Secret Service provider only fails on use (SEC 02).
class PlatformSecureKeyStore implements SecureKeyStore {
  PlatformSecureKeyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;
  static const _probe = 'finance_store/probe';

  @override
  Future<bool> isAvailable() async {
    try {
      await _storage.write(key: _probe, value: 'ok');
      final value = await _storage.read(key: _probe);
      await _storage.delete(key: _probe);
      return value == 'ok';
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    final value = await _storage.read(key: name);
    return value == null ? null : base64Decode(value);
  }

  @override
  Future<void> write(String name, Uint8List material) =>
      _storage.write(key: name, value: base64Encode(material));

  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}
