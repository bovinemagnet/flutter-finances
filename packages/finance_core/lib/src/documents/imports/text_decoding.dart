import 'dart:convert';
import 'dart:typed_data';

/// Text encodings offered for CSV import (IMP 01).
enum TextEncoding { utf8, windows1252, latin1 }

class TextDecodingException implements Exception {
  TextDecodingException(this.encoding, this.message);
  final TextEncoding encoding;
  final String message;

  @override
  String toString() =>
      'The file is not valid ${encoding.name} text: $message. '
      'Choose a different encoding.';
}

/// Windows-1252 code points for bytes 0x80 to 0x9F. Undefined bytes map to
/// the C1 control character with the same value, as browsers do.
const _cp1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

/// Decodes [bytes] as [encoding]. A UTF-8 byte order mark is removed;
/// malformed UTF-8 throws [TextDecodingException] instead of guessing.
String decodeText(Uint8List bytes, TextEncoding encoding) {
  switch (encoding) {
    case TextEncoding.utf8:
      final start = _hasUtf8Bom(bytes) ? 3 : 0;
      try {
        return utf8.decode(Uint8List.sublistView(bytes, start));
      } on FormatException catch (error) {
        throw TextDecodingException(encoding, error.message);
      }
    case TextEncoding.latin1:
      return latin1.decode(bytes);
    case TextEncoding.windows1252:
      final codes = Uint16List(bytes.length);
      for (var i = 0; i < bytes.length; i++) {
        final b = bytes[i];
        codes[i] = b >= 0x80 && b <= 0x9F ? _cp1252High[b - 0x80] : b;
      }
      return String.fromCharCodes(codes);
  }
}

bool _hasUtf8Bom(Uint8List bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xEF &&
    bytes[1] == 0xBB &&
    bytes[2] == 0xBF;

/// Suggests an encoding: UTF-8 when there is a BOM or the bytes are valid
/// UTF-8, otherwise Windows-1252 (the usual encoding of older bank exports).
TextEncoding detectEncoding(Uint8List bytes) {
  if (_hasUtf8Bom(bytes)) return TextEncoding.utf8;
  try {
    utf8.decode(bytes);
    return TextEncoding.utf8;
  } on FormatException {
    return TextEncoding.windows1252;
  }
}
