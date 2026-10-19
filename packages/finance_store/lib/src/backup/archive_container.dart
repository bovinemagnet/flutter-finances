import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import '../crypto/aead.dart';
import '../crypto/kdf.dart';

class BackupDecryptionException implements Exception {
  BackupDecryptionException(this.message);
  final String message;

  @override
  String toString() =>
      'BackupDecryptionException: $message (wrong recovery secret or a '
      'damaged archive)';
}

class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;

  @override
  String toString() => 'BackupFormatException: $message';
}

/// Encrypted backup container, version 1 (DATA 01).
///
/// ```
/// "FSBACKUP"                      8 ASCII bytes
/// header length                   uint32, big-endian
/// header                          UTF-8 JSON, not secret: cipher, Argon2id
///                                 parameters, salt, nonce prefix, chunk size
/// chunk*                          uint32 length, then nonce || ciphertext
///                                 || tag (AES-256-GCM)
/// ```
///
/// The key is Argon2id(recovery secret, salt). Chunk *i* uses the nonce
/// `prefix(8) || uint32(i)` and the associated data
/// `SHA-256(header) || final flag`, so chunks cannot be reordered, dropped,
/// moved between archives or truncated without detection. The plaintext is
/// a sequence of entries — uint16 name length, UTF-8 name, uint64 size,
/// bytes — ended by a zero name length inside the final chunk.
abstract final class BackupContainer {
  static const magic = 'FSBACKUP';
  static const format = 'finance_store.backup';
  static const version = 1;
  static const defaultChunkSize = 1024 * 1024;
}

Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);
Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
Uint8List _u64(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v);

Uint8List _nonce(Uint8List prefix, int index) => Uint8List(12)
  ..setAll(0, prefix)
  ..setAll(8, _u32(index));

/// Streams entries into an encrypted archive, written to a temporary file,
/// flushed to disk and renamed into place on [close].
class ArchiveWriter {
  ArchiveWriter._(
    this._raf,
    this._temp,
    this._target,
    this._key,
    this._prefix,
    this._headerHash,
    this._chunkSize,
  );

  static Future<ArchiveWriter> create(
    File target,
    String recoverySecret, {
    Argon2idParameters kdf = Argon2idParameters.standard,
    int chunkSize = BackupContainer.defaultChunkSize,
  }) async {
    if (recoverySecret.isEmpty) {
      throw ArgumentError('A recovery secret is required');
    }
    final salt = randomBytes(16);
    final prefix = randomBytes(8);
    final key = await kdf.deriveKey(recoverySecret, salt);
    final header = utf8.encode(
      jsonEncode({
        'format': BackupContainer.format,
        'containerVersion': BackupContainer.version,
        'cipher': 'AES-256-GCM',
        'kdf': kdf.toJson(),
        'salt': base64Encode(salt),
        'noncePrefix': base64Encode(prefix),
        'chunkSize': chunkSize,
      }),
    );
    final temp = File('${target.path}.partial');
    final raf = temp.openSync(mode: FileMode.write)
      ..writeFromSync(ascii.encode(BackupContainer.magic))
      ..writeFromSync(_u32(header.length))
      ..writeFromSync(header);
    return ArchiveWriter._(
      raf,
      temp,
      target,
      key,
      prefix,
      hash.sha256.convert(header).bytes,
      chunkSize,
    );
  }

  final RandomAccessFile _raf;
  final File _temp;
  final File _target;
  final Uint8List _key;
  final Uint8List _prefix;
  final List<int> _headerHash;
  final int _chunkSize;
  final _buffer = BytesBuilder(copy: false);
  int _index = 0;
  bool _closed = false;

  void add(String name, List<int> bytes) {
    if (_closed) throw StateError('Archive closed');
    final encoded = utf8.encode(name);
    if (encoded.isEmpty || encoded.length > 0xffff) {
      throw ArgumentError.value(name, 'name');
    }
    _write(_u16(encoded.length));
    _write(encoded);
    _write(_u64(bytes.length));
    _write(bytes);
  }

  void _write(List<int> data) {
    _buffer.add(data);
    if (_buffer.length < _chunkSize) return;
    final all = _buffer.takeBytes();
    var offset = 0;
    while (all.length - offset >= _chunkSize) {
      _emit(Uint8List.sublistView(all, offset, offset + _chunkSize), false);
      offset += _chunkSize;
    }
    _buffer.add(Uint8List.sublistView(all, offset));
  }

  void _emit(Uint8List plain, bool last) {
    final sealed = sealAesGcm(
      _key,
      plain,
      aad: [..._headerHash, last ? 1 : 0],
      nonce: _nonce(_prefix, _index++),
    );
    _raf
      ..writeFromSync(_u32(sealed.length))
      ..writeFromSync(sealed);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _buffer.add(_u16(0));
    _emit(_buffer.takeBytes(), true);
    _raf
      ..flushSync()
      ..closeSync();
    _temp.renameSync(_target.path);
  }

  /// Abandons the archive and removes the partial file.
  void abort() {
    if (_closed) return;
    _closed = true;
    _raf.closeSync();
    if (_temp.existsSync()) _temp.deleteSync();
  }
}

class ArchiveEntry {
  ArchiveEntry(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Reads and authenticates an archive written by [ArchiveWriter].
class ArchiveReader {
  ArchiveReader._(this._raf, this._key, this._prefix, this._headerHash);

  static Future<ArchiveReader> open(File file, String recoverySecret) async {
    final raf = file.openSync();
    try {
      final magic = raf.readSync(8);
      if (magic.length < 8 ||
          ascii.decode(magic, allowInvalid: true) != BackupContainer.magic) {
        throw BackupFormatException('Not a finance backup');
      }
      final length = _readU32(raf);
      final headerBytes = raf.readSync(length);
      if (headerBytes.length != length) {
        throw BackupFormatException('Truncated header');
      }
      final header = (jsonDecode(utf8.decode(headerBytes)) as Map)
          .cast<String, Object?>();
      if (header['format'] != BackupContainer.format) {
        throw BackupFormatException('Unknown format ${header['format']}');
      }
      if ((header['containerVersion'] as int) > BackupContainer.version) {
        throw BackupFormatException(
          'Container version ${header['containerVersion']} is newer than '
          'this application supports',
        );
      }
      final kdf = Argon2idParameters.fromJson(
        (header['kdf'] as Map).cast<String, Object?>(),
      );
      final key = await kdf.deriveKey(
        recoverySecret,
        base64Decode(header['salt'] as String),
      );
      return ArchiveReader._(
        raf,
        key,
        base64Decode(header['noncePrefix'] as String),
        hash.sha256.convert(headerBytes).bytes,
      );
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _raf;
  final Uint8List _key;
  final Uint8List _prefix;
  final List<int> _headerHash;
  Uint8List _plain = Uint8List(0);
  int _offset = 0;
  int _index = 0;
  bool _final = false;

  static int _readU32(RandomAccessFile raf) {
    final bytes = raf.readSync(4);
    if (bytes.length != 4) throw BackupFormatException('Truncated archive');
    return bytes.buffer.asByteData().getUint32(0);
  }

  void _readChunk() {
    if (_final) throw BackupFormatException('Data after the final chunk');
    final length = _readU32(_raf);
    final sealed = _raf.readSync(length);
    if (sealed.length != length) {
      throw BackupFormatException('Truncated archive');
    }
    final expected = _nonce(_prefix, _index);
    for (var i = 0; i < 12; i++) {
      if (sealed[i] != expected[i]) {
        throw BackupDecryptionException('chunk $_index out of order');
      }
    }
    Uint8List? plain;
    for (final last in [false, true]) {
      try {
        plain = openAesGcm(_key, sealed, aad: [..._headerHash, last ? 1 : 0]);
        _final = last;
        break;
      } on DecryptionException {
        continue;
      }
    }
    if (plain == null) {
      throw BackupDecryptionException('chunk $_index does not authenticate');
    }
    _index++;
    final rest = _plain.length - _offset;
    _plain = Uint8List(rest + plain.length)
      ..setAll(0, Uint8List.sublistView(_plain, _offset))
      ..setAll(rest, plain);
    _offset = 0;
  }

  Uint8List _take(int n) {
    while (_plain.length - _offset < n) {
      _readChunk();
    }
    final out = Uint8List.sublistView(_plain, _offset, _offset + n);
    _offset += n;
    return Uint8List.fromList(out);
  }

  /// The next entry, or null at the authenticated end of the archive.
  ArchiveEntry? next() {
    final nameLength = _take(2).buffer.asByteData().getUint16(0);
    if (nameLength == 0) {
      if (!_final || _offset != _plain.length) {
        throw BackupFormatException('Archive ended early');
      }
      if (_raf.positionSync() != _raf.lengthSync()) {
        throw BackupFormatException('Unexpected data after the archive');
      }
      return null;
    }
    final name = utf8.decode(_take(nameLength));
    final size = _take(8).buffer.asByteData().getUint64(0);
    return ArchiveEntry(name, _take(size));
  }

  void close() => _raf.closeSync();
}

/// Reads every entry of an archive into memory.
Future<Map<String, Uint8List>> readBackupEntries(
  File file,
  String recoverySecret,
) async {
  final reader = await ArchiveReader.open(file, recoverySecret);
  try {
    final entries = <String, Uint8List>{};
    for (var e = reader.next(); e != null; e = reader.next()) {
      entries[e.name] = e.bytes;
    }
    return entries;
  } finally {
    reader.close();
  }
}

/// Writes [entries] in order as a new archive.
Future<void> writeBackupEntries(
  File file,
  Map<String, List<int>> entries,
  String recoverySecret, {
  Argon2idParameters kdf = Argon2idParameters.standard,
}) async {
  final writer = await ArchiveWriter.create(file, recoverySecret, kdf: kdf);
  try {
    for (final e in entries.entries) {
      writer.add(e.key, e.value);
    }
    await writer.close();
  } catch (_) {
    writer.abort();
    rethrow;
  }
}
