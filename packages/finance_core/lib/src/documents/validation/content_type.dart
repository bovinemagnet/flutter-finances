import 'dart:typed_data';

/// Document formats accepted for receipts in P0 (REC 05).
enum DocumentContentType {
  jpeg('image/jpeg'),
  png('image/png'),
  heic('image/heic'),
  heif('image/heif'),
  pdf('application/pdf');

  const DocumentContentType(this.mimeType);

  final String mimeType;

  bool get isImage => this != pdf;

  static DocumentContentType fromMimeType(String mimeType) => values.firstWhere(
    (t) => t.mimeType == mimeType,
    orElse: () => throw FormatException('Unsupported content type', mimeType),
  );
}

/// HEIF brands that carry HEVC-coded images (reported as HEIC).
const _heicBrands = {
  'heic',
  'heix',
  'hevc',
  'hevx',
  'heim',
  'heis',
  'hevm',
  'hevs',
};

/// Generic HEIF brands (reported as HEIF).
const _heifBrands = {'mif1', 'msf1'};

/// How far into a file a PDF header may start; readers tolerate leading
/// bytes before `%PDF-`.
const pdfHeaderSearchWindow = 1024;

/// Identifies the actual format from magic bytes, ignoring any file name
/// or claimed type (SEC 04). Returns null for anything unsupported.
///
/// - JPEG: `FF D8 FF` at offset 0.
/// - PNG: the 8-byte PNG signature at offset 0.
/// - HEIC/HEIF: `ftyp` at offset 4 followed by a major brand; HEVC brands
///   (`heic`, `heix`, `hevc`, `hevx`, `heim`, `heis`, `hevm`, `hevs`) are
///   HEIC, `mif1` and `msf1` are HEIF.
/// - PDF: `%PDF-` starting within the first 1024 bytes.
DocumentContentType? sniffContentType(Uint8List bytes) {
  if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) {
    return DocumentContentType.jpeg;
  }
  if (_startsWith(bytes, const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ])) {
    return DocumentContentType.png;
  }
  if (bytes.length >= 12 && _ascii(bytes, 4, 4) == 'ftyp') {
    final brand = _ascii(bytes, 8, 4);
    if (_heicBrands.contains(brand)) return DocumentContentType.heic;
    if (_heifBrands.contains(brand)) return DocumentContentType.heif;
    return null;
  }
  if (indexOfBytes(
        bytes,
        const [0x25, 0x50, 0x44, 0x46, 0x2D],
        0,
        pdfHeaderSearchWindow + 5,
      ) >=
      0) {
    return DocumentContentType.pdf;
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(bytes.sublist(offset, offset + length));

/// Index of [needle] in [bytes] between [start] and [end] (exclusive), or -1.
int indexOfBytes(Uint8List bytes, List<int> needle, [int start = 0, int? end]) {
  final limit = (end == null || end > bytes.length) ? bytes.length : end;
  outer:
  for (var i = start; i + needle.length <= limit; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
