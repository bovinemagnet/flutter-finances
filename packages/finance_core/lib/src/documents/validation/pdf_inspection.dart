import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What can be learnt about a PDF without rendering it.
@immutable
class PdfInfo {
  const PdfInfo({
    required this.readable,
    required this.encrypted,
    required this.pageCount,
  });

  /// False when the file is truncated or has no recognisable structure.
  final bool readable;

  /// True when a trailer or cross-reference stream names an `/Encrypt`
  /// dictionary.
  final bool encrypted;

  /// Conservative page count: the larger of the number of visible `/Page`
  /// objects and the largest `/Count` in a page tree node. Null when the
  /// page tree is hidden inside compressed object streams, in which case
  /// the platform renderer must confirm the count.
  final int? pageCount;
}

final _pageObject = RegExp(r'/Type\s*/Page(?![A-Za-z])');
final _count = RegExp(r'/Count\s+(\d+)');
final _encrypt = RegExp(r'/Encrypt(?![A-Za-z])');
final _xrefStream = RegExp(r'/Type\s*/XRef(?![A-Za-z])');

/// Inspects PDF bytes for structure, encryption and page count (REC 05).
///
/// This reads the raw syntax only; it never decompresses streams, so the
/// resource cost is bounded by the file size limit.
PdfInfo inspectPdf(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final tailStart = text.length > 1024 ? text.length - 1024 : 0;
  final hasEof = text.indexOf('%%EOF', tailStart) >= 0;
  final hasStartXref = text.contains('startxref');

  final encrypted = _trailerDictionaries(text).any(_encrypt.hasMatch);

  final pageObjects = _pageObject.allMatches(text).length;
  var maxCount = 0;
  for (final match in _count.allMatches(text)) {
    final value = int.tryParse(match[1]!) ?? 0;
    if (value > maxCount) maxCount = value;
  }
  final visiblePages = pageObjects > maxCount ? pageObjects : maxCount;
  final hiddenPageTree = visiblePages == 0 && text.contains('/ObjStm');

  final readable =
      hasEof && hasStartXref && (visiblePages > 0 || hiddenPageTree);
  return PdfInfo(
    readable: readable,
    encrypted: encrypted,
    pageCount: visiblePages > 0 ? visiblePages : null,
  );
}

/// Classic `trailer` dictionaries (all of them, to cover incremental
/// updates and linearised files) and cross-reference stream dictionaries.
Iterable<String> _trailerDictionaries(String text) sync* {
  var at = text.indexOf('trailer');
  while (at >= 0) {
    final end = text.indexOf('startxref', at);
    yield text.substring(at, end < 0 ? text.length : end);
    at = text.indexOf('trailer', at + 7);
  }
  for (final match in _xrefStream.allMatches(text)) {
    final objStart = text.lastIndexOf('obj', match.start);
    final streamStart = text.indexOf('stream', match.end);
    yield text.substring(
      objStart < 0 ? match.start : objStart,
      streamStart < 0 ? text.length : streamStart,
    );
  }
}
