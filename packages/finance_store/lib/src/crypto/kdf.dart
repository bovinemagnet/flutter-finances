import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:meta/meta.dart';

/// Argon2id cost parameters, stored beside every derived key so they can be
/// raised later without breaking existing envelopes.
@immutable
class Argon2idParameters {
  const Argon2idParameters({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  factory Argon2idParameters.fromJson(Map<String, Object?> json) {
    if (json['algorithm'] != 'argon2id') {
      throw FormatException('Unsupported KDF', json['algorithm']);
    }
    return Argon2idParameters(
      memoryKiB: json['memoryKiB'] as int,
      iterations: json['iterations'] as int,
      parallelism: json['parallelism'] as int,
    );
  }

  /// RFC 9106 second recommended option: 64 MiB, 3 passes, 4 lanes.
  static const standard = Argon2idParameters(
    memoryKiB: 65536,
    iterations: 3,
    parallelism: 4,
  );

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() => {
    'algorithm': 'argon2id',
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
  };

  /// Derives a 256-bit key from [secret] and a random [salt].
  Future<Uint8List> deriveKey(String secret, List<int> salt) async {
    final key = await DartArgon2id(
      parallelism: parallelism,
      memory: memoryKiB,
      iterations: iterations,
      hashLength: 32,
    ).deriveKeyFromPassword(password: secret, nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }
}
