import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import '../text/normalise.dart';
import 'document_asset.dart';
import 'receipt.dart';
import 'receipt_link.dart';
import 'receipt_states.dart';

/// Everything search needs to know about one receipt.
@immutable
class ReceiptSearchEntry {
  ReceiptSearchEntry({
    required this.receipt,
    this.suggested = const ReceiptFields(),
    this.extractedText,
    Iterable<DocumentAsset> assets = const [],
    Iterable<ReceiptTransactionLink> links = const [],
  }) : assets = List.unmodifiable(assets),
       links = List.unmodifiable(links);

  final Receipt receipt;

  /// Best extraction candidates, used where nothing is confirmed.
  final ReceiptFields suggested;

  /// Recognised text from the latest extraction.
  final String? extractedText;
  final List<DocumentAsset> assets;
  final List<ReceiptTransactionLink> links;

  /// Confirmed values, falling back to suggestions field by field.
  ReceiptFields get fields => suggested.merge(receipt.confirmed);

  /// True when a source image is on this device or retrievable from the
  /// server; false for "Image pending" or a missing original.
  bool get hasImage => assets.any(
    (a) =>
        a.kind == AssetKind.source &&
        (a.presentLocally || a.uploadState == UploadState.uploaded),
  );

  bool get isMatched => links.isNotEmpty;
}

/// A receipt search (REC 07). Every given criterion must hold.
///
/// [text] matches when each of its normalised words is the start of a word
/// in the merchant, notes, tags, extracted text, total or date.
/// Amount criteria compare the receipt total in the same currency.
@immutable
class ReceiptQuery {
  const ReceiptQuery({
    this.text,
    this.merchant,
    this.from,
    this.to,
    this.amount,
    this.minAmount,
    this.maxAmount,
    this.tags = const {},
    this.unmatchedOnly = false,
    this.extractionFailedOnly = false,
    this.missingImageOnly = false,
    this.includeDeleted = false,
  });

  final String? text;
  final String? merchant;
  final LocalDate? from;
  final LocalDate? to;
  final Money? amount;
  final Money? minAmount;
  final Money? maxAmount;
  final Set<String> tags;
  final bool unmatchedOnly;
  final bool extractionFailedOnly;
  final bool missingImageOnly;
  final bool includeDeleted;
}

/// Filters [entries] by [query], newest effective date first; receipts
/// without a date follow, newest capture first.
List<ReceiptSearchEntry> searchReceipts(
  Iterable<ReceiptSearchEntry> entries,
  ReceiptQuery query,
) {
  final textWords = _words(normaliseText(query.text ?? ''));
  final merchantWords = _words(
    query.merchant == null ? '' : normaliseMerchant(query.merchant!),
  );
  final results = entries.where((entry) {
    final receipt = entry.receipt;
    final fields = entry.fields;
    if (receipt.isDeleted && !query.includeDeleted) return false;
    if (query.unmatchedOnly && entry.isMatched) return false;
    if (query.extractionFailedOnly &&
        receipt.extractionState != ExtractionState.extractionFailed) {
      return false;
    }
    if (query.missingImageOnly && entry.hasImage) return false;
    if (!receipt.tags.containsAll(query.tags)) return false;
    final date = fields.date;
    if (query.from != null && (date == null || date < query.from!)) {
      return false;
    }
    if (query.to != null && (date == null || date > query.to!)) return false;
    final total = fields.total;
    if (!_amountMatches(total, query)) return false;
    if (merchantWords.isNotEmpty &&
        !_allPrefixed(
          merchantWords,
          _words(normaliseMerchant(fields.merchant ?? '')),
        )) {
      return false;
    }
    if (textWords.isNotEmpty) {
      final haystack = normaliseText(
        [
          fields.merchant,
          receipt.notes,
          ...receipt.tags,
          entry.extractedText,
          total?.toDecimalString(),
          date?.toString(),
        ].whereType<String>().join(' '),
      );
      if (!_allPrefixed(textWords, _words(haystack))) return false;
    }
    return true;
  }).toList();
  results.sort((a, b) {
    final da = a.fields.date;
    final db = b.fields.date;
    if (da != null && db != null && da != db) return db.compareTo(da);
    if (da == null && db != null) return 1;
    if (da != null && db == null) return -1;
    return b.receipt.capturedAt.compareTo(a.receipt.capturedAt);
  });
  return results;
}

List<String> _words(String normalised) =>
    normalised.isEmpty ? const [] : normalised.split(' ');

bool _allPrefixed(List<String> wanted, List<String> words) =>
    wanted.every((w) => words.any((candidate) => candidate.startsWith(w)));

bool _amountMatches(Money? total, ReceiptQuery query) {
  bool comparable(Money bound) =>
      total != null && total.currency == bound.currency;
  if (query.amount != null &&
      !(comparable(query.amount!) && total == query.amount)) {
    return false;
  }
  if (query.minAmount != null &&
      !(comparable(query.minAmount!) && total! >= query.minAmount!)) {
    return false;
  }
  if (query.maxAmount != null &&
      !(comparable(query.maxAmount!) && total! <= query.maxAmount!)) {
    return false;
  }
  return true;
}
