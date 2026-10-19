import 'dart:convert';
import 'dart:typed_data';

/// Minimal but structurally valid file headers for content validation tests.

Uint8List jpegBytes({int width = 800, int height = 1200, bool withSof = true}) {
  final bytes = <int>[
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
    ...ascii.encode('JFIF'), 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
    0x00, 0x00,
  ];
  if (withSof) {
    bytes.addAll([
      0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, precision 8
      (height >> 8) & 0xFF, height & 0xFF,
      (width >> 8) & 0xFF, width & 0xFF,
      0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
    ]);
  }
  bytes.addAll([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
  bytes.addAll(List.filled(32, 0x55));
  bytes.addAll([0xFF, 0xD9]);
  return Uint8List.fromList(bytes);
}

Uint8List pngBytes({int width = 640, int height = 480}) {
  int b(int value, int shift) => (value >> shift) & 0xFF;
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    0x00, 0x00, 0x00, 0x0D, ...ascii.encode('IHDR'),
    b(width, 24), b(width, 16), b(width, 8), b(width, 0),
    b(height, 24), b(height, 16), b(height, 8), b(height, 0),
    0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // depth .. crc
    0x00, 0x00, 0x00, 0x00, ...ascii.encode('IEND'), 0xAE, 0x42, 0x60, 0x82,
  ]);
}

Uint8List heicBytes({
  String brand = 'heic',
  int? width = 3024,
  int? height = 4032,
}) {
  int b(int value, int shift) => (value >> shift) & 0xFF;
  final bytes = <int>[
    0x00,
    0x00,
    0x00,
    0x18,
    ...ascii.encode('ftyp'),
    ...ascii.encode(brand),
    0x00,
    0x00,
    0x00,
    0x00,
    ...ascii.encode('mif1'),
    ...ascii.encode(brand),
  ];
  if (width != null && height != null) {
    bytes.addAll([
      0x00,
      0x00,
      0x00,
      0x14,
      ...ascii.encode('ispe'),
      0x00,
      0x00,
      0x00,
      0x00,
      b(width, 24),
      b(width, 16),
      b(width, 8),
      b(width, 0),
      b(height, 24),
      b(height, 16),
      b(height, 8),
      b(height, 0),
    ]);
  }
  bytes.addAll(List.filled(16, 0));
  return Uint8List.fromList(bytes);
}

/// A small PDF with [pages] page objects. [encrypted] adds an `/Encrypt`
/// entry to the trailer; [truncated] drops the end-of-file marker.
Uint8List pdfBytes({
  int pages = 1,
  bool encrypted = false,
  bool truncated = false,
  bool xrefStream = false,
}) {
  final buffer = StringBuffer('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n');
  buffer.write('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  final kids = [for (var i = 0; i < pages; i++) '${i + 3} 0 R'].join(' ');
  buffer.write(
    '2 0 obj\n<< /Type /Pages /Kids [$kids] /Count $pages >>\nendobj\n',
  );
  for (var i = 0; i < pages; i++) {
    buffer.write(
      '${i + 3} 0 obj\n<< /Type /Page /Parent 2 0 R '
      '/MediaBox [0 0 595 842] >>\nendobj\n',
    );
  }
  final encrypt = encrypted ? ' /Encrypt ${pages + 3} 0 R' : '';
  if (xrefStream) {
    buffer.write(
      '${pages + 4} 0 obj\n<< /Type /XRef /Size ${pages + 5} '
      '/Root 1 0 R$encrypt /Length 0 >>\nstream\n\nendstream\nendobj\n',
    );
  } else {
    buffer.write('xref\n0 ${pages + 3}\n0000000000 65535 f \n');
    buffer.write('trailer\n<< /Size ${pages + 3} /Root 1 0 R$encrypt >>\n');
  }
  buffer.write('startxref\n9\n');
  if (!truncated) buffer.write('%%EOF\n');
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}
