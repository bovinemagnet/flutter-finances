import 'dart:typed_data';

import 'package:finance_app/platform/image_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  Uint8List jpegWithGps() {
    final image = img.Image(width: 4, height: 4);
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(27, 1);
    image.exif.imageIfd['Make'] = img.IfdValueAscii('Phone');
    return img.encodeJpg(image);
  }

  test('removes EXIF from JPEG copies but keeps the image decodable', () {
    final source = jpegWithGps();
    expect(img.decodeJpg(source)!.exif.gpsIfd.isEmpty, isFalse);
    final stripped = stripImageMetadata(source);
    final decoded = img.decodeJpg(stripped)!;
    expect(decoded.exif.isEmpty, isTrue);
    expect(decoded.width, 4);
    expect(stripped.length, lessThan(source.length));
  });

  test('removes eXIf and text chunks from PNG copies', () {
    final image = img.Image(width: 2, height: 2);
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(27, 1);
    image.textData = {'Location': 'Brisbane'};
    final source = img.encodePng(image);
    final stripped = stripImageMetadata(source);
    final decoded = img.decodePng(stripped)!;
    expect(decoded.exif.isEmpty, isTrue);
    expect(decoded.textData, isNull);
    expect(decoded.width, 2);
  });

  test('returns other content unchanged', () {
    final pdf = Uint8List.fromList('%PDF-1.7 test'.codeUnits);
    expect(stripImageMetadata(pdf), same(pdf));
  });
}
