import 'package:finance_app/platform/image_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _checkerboard(int size, int cell) {
  final image = img.Image(width: size, height: size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final on = ((x ~/ cell) + (y ~/ cell)).isEven;
      image.setPixelRgb(x, y, on ? 255 : 0, on ? 255 : 0, on ? 255 : 0);
    }
  }
  return image;
}

void main() {
  test('rotates a quarter turn and crops by fractions', () {
    final source = img.encodePng(img.Image(width: 40, height: 20));
    final rotated = img.decodeImage(
      applyEdits(source, const ImageEdits(quarterTurns: 1)),
    )!;
    expect((rotated.width, rotated.height), (20, 40));
    final cropped = img.decodeImage(
      applyEdits(source, const ImageEdits(crop: CropRect(0.25, 0, 0.5, 1))),
    )!;
    expect((cropped.width, cropped.height), (20, 20));
  });

  test('contrast enhancement stretches a faded receipt to full range', () {
    final faded = img.Image(width: 10, height: 1);
    for (var x = 0; x < 10; x++) {
      final v = 120 + x * 4; // 120..156, like faded thermal paper
      faded.setPixelRgb(x, 0, v, v, v);
    }
    final out = img.decodeImage(
      applyEdits(img.encodePng(faded), const ImageEdits(enhanceContrast: true)),
    )!;
    final values = [for (var x = 0; x < 10; x++) out.getPixel(x, 0).r.toInt()];
    expect(values.first, lessThan(20));
    expect(values.last, greaterThan(235));
  });

  test('sharp detail scores higher than a blurred copy', () {
    final sharp = _checkerboard(64, 4);
    final blurred = img.gaussianBlur(sharp.clone(), radius: 6);
    final sharpScore = assessQuality(img.encodePng(sharp)).sharpness;
    final blurScore = assessQuality(img.encodePng(blurred)).sharpness;
    expect(sharpScore, greaterThan(blurScore * 5));
    expect(assessQuality(img.encodePng(blurred)).likelyBlurred, isTrue);
    expect(assessQuality(img.encodePng(sharp)).likelyBlurred, isFalse);
  });

  test('produces the 9 by 8 greyscale matrix used for duplicate detection', () {
    final matrix = differenceHashMatrix(img.encodePng(_checkerboard(64, 8)));
    expect(matrix.length, 8);
    expect(matrix.every((row) => row.length == 9), isTrue);
  });
}
