import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../validation/content_type.dart';
import 'ocr_result.dart';

/// What a provider does with receipt data, shown before consent (AUTO 02).
@immutable
class ProviderDataUse {
  const ProviderDataUse({
    required this.requiresConsent,
    required this.retention,
    required this.region,
  });

  /// True for anything that leaves the device. On-device engines may
  /// return false.
  final bool requiresConsent;

  /// Documented retention, for example "Deleted after processing".
  final String retention;

  /// Where the data is processed, for example "Australia".
  final String region;
}

/// The only boundary through which a text recognition engine, an optional
/// cloud extraction service or a language model may contribute to receipt
/// processing (OCR 02, AUTO 02).
///
/// A provider returns recognised text and geometry as an [OcrResult] and
/// nothing else. That text is untrusted data: the deterministic receipt
/// parser turns it into candidates, arithmetic and ledger validation stay
/// local, and only the user can confirm fields, approve a match or post an
/// entry. A provider has no access to accounts, commands or matches.
/// Implementations live in platform or service adapters; callers must
/// obtain explicit consent first when [ProviderDataUse.requiresConsent].
abstract interface class ExtractionProvider {
  String get name;
  String get version;
  ProviderDataUse get dataUse;

  /// Recognises text in a validated document.
  Future<OcrResult> recognise(Uint8List bytes, DocumentContentType type);
}
