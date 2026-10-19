import 'dart:io';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:path_provider/path_provider.dart';

import 'capabilities.dart';

class TextRecognitionException implements Exception {
  const TextRecognitionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Recognises text and geometry from receipt images (OCR 01, OCR 02). The
/// parser that turns lines into fields is shared domain code.
abstract interface class TextRecogniser {
  Future<bool> isAvailable();
  Future<OcrResult> recognise(List<Uint8List> images);
}

Future<File> _tempImage(Uint8List bytes, int index) async {
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/ocr-${DateTime.now().microsecondsSinceEpoch}-$index',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// ML Kit Text Recognition v2 on iOS and Android.
class MlKitTextRecogniser implements TextRecogniser {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    final recogniser = mlkit.TextRecognizer(
      script: mlkit.TextRecognitionScript.latin,
    );
    final lines = <OcrLine>[];
    try {
      for (final (index, bytes) in images.indexed) {
        final file = await _tempImage(bytes, index);
        try {
          final result = await recogniser.processImage(
            mlkit.InputImage.fromFilePath(file.path),
          );
          for (final block in result.blocks) {
            for (final line in block.lines) {
              final r = line.boundingBox;
              lines.add(
                OcrLine(
                  line.text,
                  box: BoundingBox(
                    r.left,
                    r.top + index * 100000,
                    r.width,
                    r.height,
                  ),
                  engineConfidence: line.confidence,
                ),
              );
            }
          }
        } finally {
          await file.delete();
        }
      }
    } on Exception catch (e) {
      throw TextRecognitionException('Text recognition failed: $e');
    } finally {
      await recogniser.close();
    }
    return OcrResult(
      engine: 'mlkit-text-v2',
      engineVersion: '0.17',
      lines: lines,
    );
  }
}

/// Tesseract on desktop, used only when it is installed with English data.
class TesseractTextRecogniser implements TextRecogniser {
  @override
  Future<bool> isAvailable() async =>
      (await tesseractLanguages()).contains('eng');

  @override
  Future<OcrResult> recognise(List<Uint8List> images) async {
    final version = await Process.run('tesseract', ['--version']);
    final buffer = StringBuffer();
    for (final (index, bytes) in images.indexed) {
      final file = await _tempImage(bytes, index);
      try {
        final result = await Process.run('tesseract', [
          file.path,
          'stdout',
          '-l',
          'eng',
          '--psm',
          '4',
        ]);
        if (result.exitCode != 0) {
          throw TextRecognitionException('Tesseract failed: ${result.stderr}');
        }
        buffer.writeln(result.stdout);
      } finally {
        await file.delete();
      }
    }
    return OcrResult.fromText(
      buffer.toString(),
      engine: 'tesseract',
      engineVersion: (version.stdout as String).split('\n').first.trim(),
    );
  }
}

/// No engine on this device: receipts are kept and fields entered by hand.
class UnavailableTextRecogniser implements TextRecogniser {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<OcrResult> recognise(List<Uint8List> images) async =>
      throw const TextRecognitionException(
        'Text recognition is not available on this device; enter the details',
      );
}
