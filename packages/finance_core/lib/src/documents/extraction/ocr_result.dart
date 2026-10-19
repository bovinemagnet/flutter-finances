import 'package:meta/meta.dart';

/// A recognised line's position on the page, in the engine's pixel space.
@immutable
class BoundingBox {
  const BoundingBox(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get centreY => top + height / 2;

  @override
  bool operator ==(Object other) =>
      other is BoundingBox &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// One line of recognised text with optional geometry.
@immutable
class OcrLine {
  const OcrLine(this.text, {this.box, this.engineConfidence});

  final String text;
  final BoundingBox? box;

  /// Whatever the engine reported, kept for provenance only. It is not
  /// calibrated and is never shown as a percentage.
  final double? engineConfidence;
}

/// The original output of a text recognition engine (OCR 01, OCR 03). It
/// is persisted unchanged next to the parsed candidates.
@immutable
class OcrResult {
  OcrResult({
    required this.engine,
    required this.engineVersion,
    required List<OcrLine> lines,
  }) : lines = List.unmodifiable(lines);

  /// Splits plain text into lines without geometry.
  factory OcrResult.fromText(
    String text, {
    required String engine,
    required String engineVersion,
  }) => OcrResult(
    engine: engine,
    engineVersion: engineVersion,
    lines: [
      for (final line in text.split(RegExp(r'\r\n|\r|\n'))) OcrLine(line),
    ],
  );

  final String engine;
  final String engineVersion;
  final List<OcrLine> lines;

  String get text => lines.map((l) => l.text).join('\n');
}
