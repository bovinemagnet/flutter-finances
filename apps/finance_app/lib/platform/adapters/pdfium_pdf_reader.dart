import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../pdf_reader.dart';

/// Reads PDFs on the device with PDFium. A PDF may have been forwarded from
/// anywhere, so nothing in it runs: this only asks for text and page images.
class PdfiumPdfReader implements PdfReader {
  PdfiumPdfReader({required this.cacheDirectory});

  final String cacheDirectory;

  /// Sharp enough for recognition without a large page using much memory.
  static const _dotsPerInch = 200;
  static const _longestEdge = 2500;

  Future<void>? _ready;

  Future<void> _start() => _ready ??= () async {
    Pdfrx.cacheDirectoryPath ??= cacheDirectory;
    await PdfrxEntryFunctions.instance.init();
  }();

  Future<T> _open<T>(
    Uint8List pdf,
    Future<T> Function(PdfDocument document) read,
  ) async {
    await _start();
    final PdfDocument document;
    try {
      document = await PdfDocument.openData(pdf);
    } on PdfPasswordException {
      throw const PdfReadException('This PDF is protected by a password');
    } on Exception catch (e) {
      throw PdfReadException('This PDF could not be read: $e');
    }
    try {
      return await read(document);
    } on PdfReadException {
      rethrow;
    } on Exception catch (e) {
      throw PdfReadException('This PDF could not be read: $e');
    } finally {
      await document.dispose();
    }
  }

  @override
  Future<List<String>> pageText(Uint8List pdf, {required int maxPages}) =>
      _open(pdf, (document) async {
        return [
          for (final page in document.pages.take(maxPages))
            (await page.loadText())?.fullText ?? '',
        ];
      });

  @override
  Future<Uint8List> renderPage(Uint8List pdf, int pageIndex) => _open(pdf, (
    document,
  ) async {
    if (pageIndex >= document.pages.length) {
      throw const PdfReadException('This PDF has fewer pages than expected');
    }
    final page = document.pages[pageIndex];
    final longest = page.width > page.height ? page.width : page.height;
    var scale = _dotsPerInch / 72;
    if (longest * scale > _longestEdge) scale = _longestEdge / longest;
    final width = (page.width * scale).round();
    final height = (page.height * scale).round();
    final rendered = await page.render(
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
      width: width,
      height: height,
      // Scans and receipts assume white paper, and PDF pages are clear.
      backgroundColor: 0xFFFFFFFF,
    );
    if (rendered == null) {
      throw const PdfReadException('This PDF page could not be drawn');
    }
    try {
      final pixels = rendered.pixels;
      // Encoding a full page would otherwise hold up the interface.
      return await Isolate.run(
        () => img.encodeJpg(
          img.Image.fromBytes(
            width: width,
            height: height,
            bytes: pixels.buffer,
            bytesOffset: pixels.offsetInBytes,
            numChannels: 4,
            order: img.ChannelOrder.bgra,
          ),
          quality: 90,
        ),
      );
    } finally {
      rendered.dispose();
    }
  });
}
