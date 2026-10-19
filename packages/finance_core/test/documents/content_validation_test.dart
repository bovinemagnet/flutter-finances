import 'dart:convert';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

import 'support/sample_files.dart';

void main() {
  group('sniffContentType', () {
    test('recognises each supported type by magic bytes', () {
      expect(sniffContentType(jpegBytes()), DocumentContentType.jpeg);
      expect(sniffContentType(pngBytes()), DocumentContentType.png);
      expect(sniffContentType(heicBytes()), DocumentContentType.heic);
      expect(
        sniffContentType(heicBytes(brand: 'mif1')),
        DocumentContentType.heif,
      );
      expect(sniffContentType(pdfBytes()), DocumentContentType.pdf);
    });

    test('accepts a PDF header after leading junk within 1024 bytes', () {
      final bytes = Uint8List.fromList([
        ...List.filled(10, 0x20),
        ...pdfBytes(),
      ]);
      expect(sniffContentType(bytes), DocumentContentType.pdf);
    });

    test('returns null for unsupported content such as GIF or text', () {
      expect(
        sniffContentType(Uint8List.fromList(ascii.encode('GIF89a...'))),
        isNull,
      );
      expect(
        sniffContentType(Uint8List.fromList(utf8.encode('Date,Amount'))),
        isNull,
      );
      expect(sniffContentType(Uint8List(0)), isNull);
    });

    test('exposes MIME types', () {
      expect(DocumentContentType.jpeg.mimeType, 'image/jpeg');
      expect(DocumentContentType.heic.mimeType, 'image/heic');
      expect(DocumentContentType.pdf.mimeType, 'application/pdf');
      expect(
        DocumentContentType.fromMimeType('image/png'),
        DocumentContentType.png,
      );
    });
  });

  group('readImageDimensions', () {
    test('reads JPEG SOF, PNG IHDR and HEIF ispe dimensions', () {
      expect(
        readImageDimensions(jpegBytes(width: 1000, height: 2000)),
        const ImageDimensions(1000, 2000),
      );
      expect(
        readImageDimensions(pngBytes(width: 7, height: 9)),
        const ImageDimensions(7, 9),
      );
      expect(
        readImageDimensions(heicBytes(width: 3024, height: 4032)),
        const ImageDimensions(3024, 4032),
      );
    });

    test('returns null when the header is missing', () {
      expect(readImageDimensions(jpegBytes(withSof: false)), isNull);
      expect(readImageDimensions(heicBytes(width: null, height: null)), isNull);
    });
  });

  group('inspectPdf', () {
    test('counts pages conservatively', () {
      final info = inspectPdf(pdfBytes(pages: 3));
      expect(info.pageCount, 3);
      expect(info.encrypted, isFalse);
      expect(info.readable, isTrue);
    });

    test('detects /Encrypt in a classic trailer and an xref stream', () {
      expect(inspectPdf(pdfBytes(encrypted: true)).encrypted, isTrue);
      expect(
        inspectPdf(pdfBytes(encrypted: true, xrefStream: true)).encrypted,
        isTrue,
      );
      expect(inspectPdf(pdfBytes(xrefStream: true)).encrypted, isFalse);
    });

    test('treats a truncated file as unreadable', () {
      expect(inspectPdf(pdfBytes(truncated: true)).readable, isFalse);
    });

    test('uses the larger of page objects and /Count', () {
      final text = latin1
          .decode(pdfBytes(pages: 2))
          .replaceFirst('/Count 2', '/Count 12');
      expect(inspectPdf(Uint8List.fromList(latin1.encode(text))).pageCount, 12);
    });
  });

  group('validateDocument', () {
    List<ContentErrorCode> errors(ContentValidationResult r) =>
        r.errors.map((e) => e.code).toList();

    test('accepts supported files and reports type, pages and dimensions', () {
      final jpeg = validateDocument(jpegBytes(width: 800, height: 1200));
      expect(jpeg.isAccepted, isTrue);
      expect(jpeg.contentType, DocumentContentType.jpeg);
      expect(jpeg.pageCount, 1);
      expect(jpeg.dimensions, const ImageDimensions(800, 1200));

      final pdf = validateDocument(pdfBytes(pages: 4));
      expect(pdf.isAccepted, isTrue);
      expect(pdf.pageCount, 4);
    });

    test('ignores the claimed extension and trusts the bytes', () {
      // A PNG named receipt.pdf is still a PNG.
      final result = validateDocument(pngBytes(), fileName: 'receipt.pdf');
      expect(result.contentType, DocumentContentType.png);
      expect(result.isAccepted, isTrue);
    });

    test('rejects empty and unsupported files with actionable messages', () {
      final empty = validateDocument(Uint8List(0));
      expect(errors(empty), [ContentErrorCode.emptyFile]);
      final gif = validateDocument(Uint8List.fromList(ascii.encode('GIF89a')));
      expect(errors(gif), [ContentErrorCode.unsupportedType]);
      expect(gif.errors.single.message, contains('JPEG, PNG, HEIC or PDF'));
      expect(gif.errors.single.code.code, 'UNSUPPORTED_TYPE');
    });

    test('enforces the file size limit', () {
      final limits = const ContentLimits(maxFileBytes: 100);
      final result = validateDocument(pdfBytes(), limits: limits);
      expect(errors(result), contains(ContentErrorCode.fileTooLarge));
      expect(const ContentLimits().maxFileBytes, 20 * 1024 * 1024);
      expect(const ContentLimits().maxPagesPerReceipt, 10);
    });

    test('enforces the page limit per file', () {
      final result = validateDocument(pdfBytes(pages: 11));
      expect(errors(result), [ContentErrorCode.tooManyPages]);
      final relaxed = validateDocument(
        pdfBytes(pages: 11),
        limits: const ContentLimits(maxPagesPerReceipt: 20),
      );
      expect(relaxed.isAccepted, isTrue);
    });

    test('rejects encrypted and unreadable PDFs', () {
      final encrypted = validateDocument(pdfBytes(encrypted: true));
      expect(errors(encrypted), [ContentErrorCode.encryptedPdf]);
      expect(encrypted.errors.single.message, contains('password'));
      final truncated = validateDocument(pdfBytes(truncated: true));
      expect(errors(truncated), [ContentErrorCode.unreadablePdf]);
    });

    test('rejects decompression-bomb image dimensions', () {
      final huge = validateDocument(pngBytes(width: 50000, height: 50000));
      expect(errors(huge), [ContentErrorCode.imageTooLarge]);
      final tooWide = validateDocument(jpegBytes(width: 30000, height: 10));
      expect(errors(tooWide), [ContentErrorCode.imageTooLarge]);
    });

    test('rejects a JPEG without a frame header as unreadable', () {
      final result = validateDocument(jpegBytes(withSof: false));
      expect(errors(result), [ContentErrorCode.unreadableImage]);
    });

    test(
      'warns but accepts HEIC whose dimensions the platform must verify',
      () {
        final result = validateDocument(heicBytes(width: null, height: null));
        expect(result.isAccepted, isTrue);
        expect(result.warnings.map((w) => w.code), [
          ContentErrorCode.dimensionsUnverified,
        ]);
      },
    );
  });

  group('checkReceiptPageLimit', () {
    test('rejects adding pages beyond the receipt limit', () {
      expect(checkReceiptPageLimit(existingPages: 8, addedPages: 2), isNull);
      final issue = checkReceiptPageLimit(existingPages: 8, addedPages: 3);
      expect(issue!.code, ContentErrorCode.tooManyPages);
      expect(issue.message, contains('10'));
    });
  });
}
