import 'dart:typed_data';

/// A PDF that could not be opened or read, for example because it is damaged
/// or protected by a password.
class PdfReadException implements Exception {
  const PdfReadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads receipts that arrive as PDFs. Throws [PdfReadException] when it cannot.
abstract interface class PdfReader {
  /// The text of each page, in order, up to [maxPages]. A scanned page has
  /// little or none.
  Future<List<String>> pageText(Uint8List pdf, {required int maxPages});

  /// One page as an image for text recognition.
  Future<Uint8List> renderPage(Uint8List pdf, int pageIndex);
}
