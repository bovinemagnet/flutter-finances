import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Builds a well-formed PDF from page bodies, as a shop's system would.
Uint8List _pdf(List<String> objects, {Map<int, Uint8List> streams = const {}}) {
  final out = BytesBuilder()..add(latin1.encode('%PDF-1.7\n'));
  final offsets = <int>[];
  for (final (i, body) in objects.indexed) {
    offsets.add(out.length);
    out.add(latin1.encode('${i + 1} 0 obj\n$body\n'));
    final stream = streams[i + 1];
    if (stream != null) {
      out
        ..add(latin1.encode('stream\n'))
        ..add(stream)
        ..add(latin1.encode('\nendstream\n'));
    }
    out.add(latin1.encode('endobj\n'));
  }
  final xref = out.length;
  final table = StringBuffer(
    'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n',
  );
  for (final offset in offsets) {
    table.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.add(
    latin1.encode(
      '$table'
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return out.toBytes();
}

/// A PDF with a real text layer: one page per entry, one line per string.
Uint8List textPdf(List<List<String>> pages) {
  final pageRefs = [for (var i = 0; i < pages.length; i++) '${4 + i * 2} 0 R'];
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${pageRefs.join(' ')}] /Count ${pages.length} >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final streams = <int, Uint8List>{};
  for (final (i, lines) in pages.indexed) {
    final content = StringBuffer('BT /F1 14 Tf 40 780 Td 18 TL\n');
    for (final line in lines) {
      content.write(
        '(${line.replaceAll('(', r'\(').replaceAll(')', r'\)')}) Tj T*\n',
      );
    }
    content.write('ET');
    final bytes = Uint8List.fromList(latin1.encode('$content'));
    objects
      ..add(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + i * 2} 0 R >>',
      )
      ..add('<< /Length ${bytes.length} >>');
    streams[5 + i * 2] = bytes;
  }
  return _pdf(objects, streams: streams);
}

/// A PDF whose one page is only a photo, as a scanner makes: it has no text.
Uint8List scannedPdf({int width = 400, int height = 600}) {
  final photo = Uint8List.fromList(
    img.encodeJpg(
      img.fill(
        img.Image(width: width, height: height),
        color: img.ColorRgb8(200, 30, 30),
      ),
    ),
  );
  const content = 'q 595 0 0 842 0 0 cm /Im0 Do Q';
  return _pdf(
    [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
          '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /XObject /Subtype /Image /Width $width /Height $height '
          '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode '
          '/Length ${photo.length} >>',
      '<< /Length ${content.length} >>',
    ],
    streams: {4: photo, 5: Uint8List.fromList(latin1.encode(content))},
  );
}
