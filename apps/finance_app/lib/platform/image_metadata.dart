import 'dart:typed_data';

/// Removes metadata that can reveal location from a new image copy (REC 02).
///
/// JPEG: drops APP1 (EXIF and XMP, which hold GPS data), APP12 and APP13
/// (IPTC) segments and comments, keeping APP0 (JFIF), APP2 (ICC profile) and
/// APP14 (Adobe colour transform) so the image still renders identically.
/// PNG: drops `eXIf`, `tEXt`, `zTXt` and `iTXt` chunks. Other content is
/// returned unchanged; imported sources are preserved as received.
Uint8List stripImageMetadata(Uint8List bytes) {
  if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return _stripJpeg(bytes);
  }
  if (bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return _stripPng(bytes);
  }
  return bytes;
}

Uint8List _stripJpeg(Uint8List bytes) {
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return bytes; // Not a well-formed segment.
    final marker = bytes[offset + 1];
    if (marker == 0xDA || marker == 0xD9) {
      out.add(Uint8List.sublistView(bytes, offset));
      return out.takeBytes();
    }
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    final end = offset + 2 + length;
    if (length < 2 || end > bytes.length) return bytes;
    final drop =
        marker == 0xE1 ||
        marker == 0xEC ||
        marker == 0xED ||
        marker == 0xFE ||
        (marker >= 0xE3 && marker <= 0xEB) ||
        marker == 0xEF;
    if (!drop) out.add(Uint8List.sublistView(bytes, offset, end));
    offset = end;
  }
  return bytes;
}

const _droppedPngChunks = {'eXIf', 'tEXt', 'zTXt', 'iTXt'};

Uint8List _stripPng(Uint8List bytes) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, 8));
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final end = offset + 12 + length;
    if (end > bytes.length) return bytes;
    if (!_droppedPngChunks.contains(type)) {
      out.add(Uint8List.sublistView(bytes, offset, end));
    }
    offset = end;
    if (type == 'IEND') break;
  }
  return out.takeBytes();
}
