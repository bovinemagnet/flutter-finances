import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'content_type.dart';

/// Pixel dimensions read from an image header without decoding pixels.
@immutable
class ImageDimensions {
  const ImageDimensions(this.width, this.height);

  final int width;
  final int height;

  int get pixels => width * height;

  @override
  bool operator ==(Object other) =>
      other is ImageDimensions &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// Reads the declared dimensions of a JPEG (SOF segment), PNG (IHDR chunk)
/// or HEIF/HEIC (`ispe` property; the largest is used because a grid image
/// declares both tile and full sizes). Returns null when no header is found.
ImageDimensions? readImageDimensions(Uint8List bytes) =>
    switch (sniffContentType(bytes)) {
      DocumentContentType.jpeg => _jpeg(bytes),
      DocumentContentType.png => _png(bytes),
      DocumentContentType.heic || DocumentContentType.heif => _heif(bytes),
      _ => null,
    };

int _u16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

int _u32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

/// Start-of-frame markers; C4 (DHT), C8 (JPG) and CC (DAC) are not frames.
bool _isSof(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

ImageDimensions? _jpeg(Uint8List b) {
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
      i += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;
    final length = _u16(b, i + 2);
    if (_isSof(marker)) {
      if (i + 9 > b.length) return null;
      return ImageDimensions(_u16(b, i + 7), _u16(b, i + 5));
    }
    i += 2 + length;
  }
  return null;
}

ImageDimensions? _png(Uint8List b) {
  if (b.length < 24 || String.fromCharCodes(b.sublist(12, 16)) != 'IHDR') {
    return null;
  }
  return ImageDimensions(_u32(b, 16), _u32(b, 20));
}

ImageDimensions? _heif(Uint8List b) {
  const ispe = [0x69, 0x73, 0x70, 0x65];
  var width = 0;
  var height = 0;
  var at = indexOfBytes(b, ispe);
  while (at >= 0 && at + 16 <= b.length) {
    final w = _u32(b, at + 8);
    final h = _u32(b, at + 12);
    if (w > width) width = w;
    if (h > height) height = h;
    at = indexOfBytes(b, ispe, at + 4);
  }
  return width == 0 || height == 0 ? null : ImageDimensions(width, height);
}
