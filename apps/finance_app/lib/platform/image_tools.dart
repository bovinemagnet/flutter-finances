import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';

/// Crop rectangle as fractions of the image (left, top, width, height).
@immutable
class CropRect {
  const CropRect(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;
}

/// Manual corrections for a receipt photo when no native scanner did them
/// (REC 02): quarter-turn rotation, crop and contrast enhancement.
@immutable
class ImageEdits {
  const ImageEdits({
    this.quarterTurns = 0,
    this.crop,
    this.enhanceContrast = false,
  });
  final int quarterTurns;
  final CropRect? crop;
  final bool enhanceContrast;

  bool get isEmpty => quarterTurns % 4 == 0 && crop == null && !enhanceContrast;
}

/// Applies [edits] and returns a JPEG readable derivative. The original is
/// kept unchanged; the derivative is a new copy without metadata.
Uint8List applyEdits(Uint8List source, ImageEdits edits) {
  var image = img.decodeImage(source);
  if (image == null) throw const FormatException('The image could not be read');
  final turns = edits.quarterTurns % 4;
  if (turns != 0) image = img.copyRotate(image, angle: 90 * turns);
  final crop = edits.crop;
  if (crop != null) {
    image = img.copyCrop(
      image,
      x: (crop.left * image.width).round(),
      y: (crop.top * image.height).round(),
      width: (crop.width * image.width).round().clamp(1, image.width),
      height: (crop.height * image.height).round().clamp(1, image.height),
    );
  }
  if (edits.enhanceContrast) image = _stretchContrast(img.grayscale(image));
  image.exif.clear();
  return img.encodeJpg(image, quality: 90);
}

/// Linear stretch between the 2nd and 98th percentile of brightness, which
/// recovers faded thermal paper without blowing out the background.
img.Image _stretchContrast(img.Image image) {
  final histogram = List<int>.filled(256, 0);
  for (final pixel in image) {
    histogram[pixel.r.toInt()]++;
  }
  final total = image.width * image.height;
  int percentile(double p) {
    var count = 0;
    for (var v = 0; v < 256; v++) {
      count += histogram[v];
      if (count >= total * p) return v;
    }
    return 255;
  }

  final low = percentile(0.02);
  final high = percentile(0.98);
  if (high <= low) return image;
  for (final pixel in image) {
    final v = (((pixel.r - low) * 255) / (high - low)).round().clamp(0, 255);
    pixel
      ..r = v
      ..g = v
      ..b = v;
  }
  return image;
}

@immutable
class QualityAssessment {
  const QualityAssessment(this.sharpness, this.width, this.height);

  /// Variance of the Laplacian on a downscaled greyscale copy.
  final double sharpness;
  final int width;
  final int height;

  /// A warning only; saving is never blocked (REC 02).
  bool get likelyBlurred => sharpness < 100;
  bool get lowResolution => width < 600 && height < 600;
}

QualityAssessment assessQuality(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return const QualityAssessment(0, 0, 0);
  final scaled = decoded.width > 512
      ? img.copyResize(decoded, width: 512)
      : decoded;
  final grey = img.grayscale(scaled.clone());
  var sum = 0.0;
  var sumSquares = 0.0;
  var n = 0;
  for (var y = 1; y < grey.height - 1; y++) {
    for (var x = 1; x < grey.width - 1; x++) {
      final l =
          4 * grey.getPixel(x, y).r -
          grey.getPixel(x - 1, y).r -
          grey.getPixel(x + 1, y).r -
          grey.getPixel(x, y - 1).r -
          grey.getPixel(x, y + 1).r;
      sum += l;
      sumSquares += l * l;
      n++;
    }
  }
  if (n == 0) return QualityAssessment(0, decoded.width, decoded.height);
  final mean = sum / n;
  return QualityAssessment(
    sumSquares / n - mean * mean,
    decoded.width,
    decoded.height,
  );
}

/// The 9 by 8 greyscale matrix that `differenceHash` in the documents
/// domain expects (MATCH 02).
List<List<int>> differenceHashMatrix(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('The image could not be read');
  }
  final small = img.grayscale(img.copyResize(decoded, width: 9, height: 8));
  return [
    for (var y = 0; y < 8; y++)
      [for (var x = 0; x < 9; x++) small.getPixel(x, y).r.toInt()],
  ];
}
