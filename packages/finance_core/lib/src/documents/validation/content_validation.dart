import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'content_type.dart';
import 'image_dimensions.dart';
import 'pdf_inspection.dart';

/// Configurable resource limits for imported documents (REC 05, SEC 04).
@immutable
class ContentLimits {
  const ContentLimits({
    this.maxFileBytes = 20 * 1024 * 1024,
    this.maxPagesPerReceipt = 10,
    this.maxImageSide = 16384,
    this.maxImagePixels = 50000000,
  });

  final int maxFileBytes;
  final int maxPagesPerReceipt;

  /// Longest permitted image edge in pixels.
  final int maxImageSide;

  /// Largest permitted decoded area. At four bytes per pixel the default
  /// bounds a decoded image to about 200 MB, which stops decompression
  /// bombs (tiny files declaring enormous dimensions).
  final int maxImagePixels;
}

enum ContentSeverity { error, warning }

/// Stable codes for content problems, shared with the server's upload
/// completion checks.
enum ContentErrorCode {
  emptyFile('EMPTY_FILE'),
  unsupportedType('UNSUPPORTED_TYPE'),
  fileTooLarge('FILE_TOO_LARGE'),
  tooManyPages('TOO_MANY_PAGES'),
  encryptedPdf('ENCRYPTED_PDF'),
  unreadablePdf('UNREADABLE_PDF'),
  unreadableImage('UNREADABLE_IMAGE'),
  imageTooLarge('IMAGE_TOO_LARGE'),
  dimensionsUnverified('DIMENSIONS_UNVERIFIED'),
  pageCountUnverified('PAGE_COUNT_UNVERIFIED');

  const ContentErrorCode(this.code);
  final String code;
}

/// One problem with an actionable message suitable for the user.
@immutable
class ContentIssue {
  const ContentIssue(
    this.code,
    this.message, {
    this.severity = ContentSeverity.error,
  });

  final ContentErrorCode code;
  final String message;
  final ContentSeverity severity;

  @override
  String toString() => '${code.code}: $message';
}

@immutable
class ContentValidationResult {
  ContentValidationResult({
    required this.sizeBytes,
    required List<ContentIssue> issues,
    this.contentType,
    this.pageCount,
    this.dimensions,
  }) : issues = List.unmodifiable(issues);

  final int sizeBytes;

  /// The type detected from the bytes, or null when unsupported.
  final DocumentContentType? contentType;

  /// One for images; the conservative count for PDFs (null if unverified).
  final int? pageCount;
  final ImageDimensions? dimensions;
  final List<ContentIssue> issues;

  List<ContentIssue> get errors =>
      issues.where((i) => i.severity == ContentSeverity.error).toList();

  List<ContentIssue> get warnings =>
      issues.where((i) => i.severity == ContentSeverity.warning).toList();

  bool get isAccepted => errors.isEmpty;
}

String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// Validates a document from its bytes alone (REC 05, SEC 04).
///
/// [fileName] is accepted for messages only; the extension never decides
/// the type. Checks run in order: empty, size, type, then type-specific
/// structure, encryption, page count and image dimensions.
ContentValidationResult validateDocument(
  Uint8List bytes, {
  String? fileName,
  ContentLimits limits = const ContentLimits(),
}) {
  final name = fileName == null ? 'This file' : '"$fileName"';
  if (bytes.isEmpty) {
    return ContentValidationResult(
      sizeBytes: 0,
      issues: [
        ContentIssue(
          ContentErrorCode.emptyFile,
          '$name is empty. Choose the file again or capture a new photo.',
        ),
      ],
    );
  }
  if (bytes.length > limits.maxFileBytes) {
    return ContentValidationResult(
      sizeBytes: bytes.length,
      contentType: sniffContentType(bytes),
      issues: [
        ContentIssue(
          ContentErrorCode.fileTooLarge,
          '$name is larger than ${_megabytes(limits.maxFileBytes)}. '
          'Export it at a lower resolution or split it into smaller files.',
        ),
      ],
    );
  }
  final type = sniffContentType(bytes);
  if (type == null) {
    return ContentValidationResult(
      sizeBytes: bytes.length,
      issues: [
        ContentIssue(
          ContentErrorCode.unsupportedType,
          '$name is not a JPEG, PNG, HEIC or PDF document. '
          'Save or export it in one of those formats and try again.',
        ),
      ],
    );
  }
  return type == DocumentContentType.pdf
      ? _validatePdf(bytes, name, limits)
      : _validateImage(bytes, type, name, limits);
}

ContentValidationResult _validatePdf(
  Uint8List bytes,
  String name,
  ContentLimits limits,
) {
  final info = inspectPdf(bytes);
  final issues = <ContentIssue>[];
  if (info.encrypted) {
    issues.add(
      ContentIssue(
        ContentErrorCode.encryptedPdf,
        '$name is password protected or encrypted. Open it, save an '
        'unprotected copy, and import that copy.',
      ),
    );
  } else if (!info.readable) {
    issues.add(
      ContentIssue(
        ContentErrorCode.unreadablePdf,
        '$name is damaged or incomplete. Download or export it again, '
        'or capture the receipt as a photo.',
      ),
    );
  } else if (info.pageCount == null) {
    issues.add(
      ContentIssue(
        ContentErrorCode.pageCountUnverified,
        'The page count of $name will be confirmed when it is rendered.',
        severity: ContentSeverity.warning,
      ),
    );
  } else if (info.pageCount! > limits.maxPagesPerReceipt) {
    issues.add(_tooManyPages(name, info.pageCount!, limits));
  }
  return ContentValidationResult(
    sizeBytes: bytes.length,
    contentType: DocumentContentType.pdf,
    pageCount: info.pageCount,
    issues: issues,
  );
}

ContentIssue _tooManyPages(String name, int pages, ContentLimits limits) =>
    ContentIssue(
      ContentErrorCode.tooManyPages,
      '$name has $pages pages; a receipt can have at most '
      '${limits.maxPagesPerReceipt}. Split the document and import each '
      'receipt separately.',
    );

ContentValidationResult _validateImage(
  Uint8List bytes,
  DocumentContentType type,
  String name,
  ContentLimits limits,
) {
  final dimensions = readImageDimensions(bytes);
  final issues = <ContentIssue>[];
  if (dimensions == null) {
    if (type == DocumentContentType.heic || type == DocumentContentType.heif) {
      issues.add(
        ContentIssue(
          ContentErrorCode.dimensionsUnverified,
          'The size of $name will be confirmed when the device decodes it.',
          severity: ContentSeverity.warning,
        ),
      );
    } else {
      issues.add(
        ContentIssue(
          ContentErrorCode.unreadableImage,
          '$name is damaged or incomplete. Capture or export the image '
          'again.',
        ),
      );
    }
  } else if (dimensions.width <= 0 ||
      dimensions.height <= 0 ||
      dimensions.width > limits.maxImageSide ||
      dimensions.height > limits.maxImageSide ||
      dimensions.pixels > limits.maxImagePixels) {
    issues.add(
      ContentIssue(
        ContentErrorCode.imageTooLarge,
        '$name declares $dimensions pixels, beyond the supported '
        '${limits.maxImageSide} pixels per side or '
        '${limits.maxImagePixels ~/ 1000000} megapixels. Resize it and try '
        'again.',
      ),
    );
  }
  return ContentValidationResult(
    sizeBytes: bytes.length,
    contentType: type,
    pageCount: 1,
    dimensions: dimensions,
    issues: issues,
  );
}

/// Checks that adding [addedPages] keeps a receipt within the page limit.
/// Returns null when allowed.
ContentIssue? checkReceiptPageLimit({
  required int existingPages,
  required int addedPages,
  ContentLimits limits = const ContentLimits(),
}) {
  final total = existingPages + addedPages;
  if (total <= limits.maxPagesPerReceipt) return null;
  return _tooManyPages('This receipt', total, limits);
}
