import 'dart:typed_data';

import 'package:finance_store/finance_store.dart';

/// A [SecureKeyStore] held in memory, standing in for a platform key store.
class MemoryKeyStore implements SecureKeyStore {
  MemoryKeyStore({this.available = true});

  bool available;
  final Map<String, Uint8List> entries = {};

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Uint8List?> read(String name) async => entries[name];

  @override
  Future<void> write(String name, Uint8List material) async {
    entries[name] = Uint8List.fromList(material);
  }

  @override
  Future<void> delete(String name) async {
    entries.remove(name);
  }
}

/// Cheap Argon2id parameters so tests do not spend time on key stretching.
const testKdf = Argon2idParameters(
  memoryKiB: 64,
  iterations: 1,
  parallelism: 1,
);
