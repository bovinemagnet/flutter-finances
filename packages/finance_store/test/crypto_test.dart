import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_store/finance_store.dart';
import 'package:test/test.dart';

import 'support/memory_key_store.dart';

void main() {
  group('HKDF-SHA256', () {
    test('matches RFC 5869 test case 1', () {
      final ikm = List<int>.filled(22, 0x0b);
      final salt = List<int>.generate(13, (i) => i);
      final info = List<int>.generate(10, (i) => 0xf0 + i);
      final okm = hkdfSha256(ikm, salt: salt, info: info, length: 42);
      expect(
        _hex(okm),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });
  });

  group('DataKey', () {
    test('generates 256-bit random keys', () {
      final a = DataKey.generate();
      final b = DataKey.generate();
      expect(a.bytes, hasLength(32));
      expect(a.bytes, isNot(equals(b.bytes)));
    });

    test('derives distinct purpose keys deterministically', () {
      final key = DataKey(Uint8List.fromList(List.filled(32, 7)));
      expect(key.derive('database'), equals(key.derive('database')));
      expect(key.derive('database'), isNot(equals(key.derive('asset/a1'))));
      expect(key.databaseKeyHex, hasLength(64));
    });
  });

  group('AES-256-GCM sealing', () {
    final key = Uint8List.fromList(List.filled(32, 3));

    test('round-trips and binds associated data', () {
      final sealed = sealAesGcm(key, utf8.encode('receipt'), aad: [1, 2]);
      expect(utf8.decode(openAesGcm(key, sealed, aad: [1, 2])), 'receipt');
      expect(
        () => openAesGcm(key, sealed, aad: [9]),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('detects tampering', () {
      final sealed = sealAesGcm(key, utf8.encode('receipt'));
      sealed[sealed.length - 1] ^= 1;
      expect(
        () => openAesGcm(key, sealed),
        throwsA(isA<DecryptionException>()),
      );
    });
  });

  group('key wrapping', () {
    test('standard Argon2id parameters follow RFC 9106 option two', () {
      expect(Argon2idParameters.standard.memoryKiB, 65536);
      expect(Argon2idParameters.standard.iterations, 3);
      expect(Argon2idParameters.standard.parallelism, 4);
    });

    test('a password wraps and unwraps the data key', () async {
      final key = DataKey.generate();
      final envelope = await PasswordWrappedKey.wrap(
        key,
        'correct horse',
        parameters: testKdf,
      );
      final json = envelope.toJson();
      expect(jsonEncode(json), isNot(contains(_hex(key.bytes))));
      final restored = PasswordWrappedKey.fromJson(json);
      final unwrapped = await restored.unwrap('correct horse');
      expect(unwrapped.bytes, equals(key.bytes));
      expect(
        () => restored.unwrap('wrong'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('platform protection stores key material in the key store', () async {
      final store = MemoryKeyStore();
      final created = await KeyProtection.platform(store).create();
      final info = created.descriptor;
      expect(info['protection'], 'platform');
      expect(store.entries, hasLength(1));
      final unlocked = await KeyProtection.platform(store).unlock(info);
      expect(unlocked.bytes, equals(created.key.bytes));
    });

    test('an unavailable platform store without a password is refused', () {
      expect(
        () => KeyProtection.select(
          platformStore: MemoryKeyStore(available: false),
        ),
        throwsA(isA<PasswordRequiredException>()),
      );
    });

    test('an unavailable platform store falls back to the password', () async {
      final protection = await KeyProtection.select(
        platformStore: MemoryKeyStore(available: false),
        password: 'secret',
        kdf: testKdf,
      );
      expect(protection, isA<PasswordKeyProtection>());
    });

    test('an available platform store is preferred', () async {
      final protection = await KeyProtection.select(
        platformStore: MemoryKeyStore(),
        password: 'secret',
      );
      expect(protection, isA<PlatformKeyProtection>());
    });

    test('creating with an unavailable platform store fails', () {
      expect(
        () => KeyProtection.platform(MemoryKeyStore(available: false)).create(),
        throwsA(isA<KeyStoreUnavailableException>()),
      );
    });

    test('changing the password rewraps the same key', () async {
      final created = await KeyProtection.password(
        'old',
        kdf: testKdf,
      ).create();
      final rewrapped = await changePassword(
        created.descriptor,
        'old',
        'new',
        kdf: testKdf,
      );
      final key = await KeyProtection.password('new').unlock(rewrapped);
      expect(key.bytes, equals(created.key.bytes));
      expect(
        () => KeyProtection.password('old').unlock(rewrapped),
        throwsA(isA<WrongPasswordException>()),
      );
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
