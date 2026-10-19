import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import '../receipts/document_asset.dart';
import '../receipts/receipt.dart';
import '../text/normalise.dart';

/// Lower-case hexadecimal SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

enum DuplicateKind { identicalFile, similarImage, economic }

/// A possible duplicate (MATCH 02). Warnings never delete anything; the
/// user decides, and legitimate repeated purchases remain possible.
@immutable
class DuplicateWarning {
  const DuplicateWarning({
    required this.kind,
    required this.otherReceiptId,
    required this.detail,
    this.otherAssetId,
  });

  final DuplicateKind kind;
  final String otherReceiptId;
  final String? otherAssetId;
  final String detail;
}

/// Assets with the same SHA-256 as [candidate] (other assets only).
List<DuplicateWarning> findIdenticalFiles(
  DocumentAsset candidate,
  Iterable<DocumentAsset> existing,
) {
  final hash = candidate.sha256.toLowerCase();
  return [
    for (final asset in existing)
      if (asset.id != candidate.id && asset.sha256.toLowerCase() == hash)
        DuplicateWarning(
          kind: DuplicateKind.identicalFile,
          otherReceiptId: asset.receiptId,
          otherAssetId: asset.id,
          detail: 'The same file is already saved',
        ),
  ];
}

/// Perceptual difference hash of a downscaled greyscale image.
///
/// [pixels] has 8 rows of 9 luminance values (the app produces it by
/// resizing to 9 by 8 and converting to greyscale). Bit `row * 8 + col` is
/// 1 when `pixels[row][col] > pixels[row][col + 1]`; bits are written row
/// by row, most significant first, as 16 lower-case hexadecimal digits.
String differenceHash(List<List<int>> pixels) {
  if (pixels.length != 8 || pixels.any((row) => row.length != 9)) {
    throw ArgumentError.value(pixels, 'pixels', 'expected 8 rows of 9 values');
  }
  final buffer = StringBuffer();
  for (final row in pixels) {
    var byte = 0;
    for (var col = 0; col < 8; col++) {
      byte = (byte << 1) | (row[col] > row[col + 1] ? 1 : 0);
    }
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Number of differing bits between two hexadecimal hashes of equal length.
int hammingDistance(String a, String b) {
  if (a.length != b.length) {
    throw ArgumentError('Hashes differ in length: ${a.length}, ${b.length}');
  }
  var distance = 0;
  for (var i = 0; i < a.length; i++) {
    var x = int.parse(a[i], radix: 16) ^ int.parse(b[i], radix: 16);
    while (x != 0) {
      distance += x & 1;
      x >>= 1;
    }
  }
  return distance;
}

/// The perceptual hash of one receipt image.
@immutable
class ImageFingerprint {
  const ImageFingerprint({
    required this.receiptId,
    required this.assetId,
    required this.dHash,
  });

  final String receiptId;
  final String assetId;
  final String dHash;
}

/// Images of other receipts within [threshold] bits of [candidate]. The
/// default of 10 of 64 bits tolerates recompression and slight crops.
List<DuplicateWarning> findSimilarImages(
  ImageFingerprint candidate,
  Iterable<ImageFingerprint> existing, {
  int threshold = 10,
}) {
  final warnings = <DuplicateWarning>[];
  for (final other in existing) {
    if (other.receiptId == candidate.receiptId) continue;
    final distance = hammingDistance(candidate.dHash, other.dHash);
    if (distance <= threshold) {
      warnings.add(
        DuplicateWarning(
          kind: DuplicateKind.similarImage,
          otherReceiptId: other.receiptId,
          otherAssetId: other.assetId,
          detail:
              'Looks like another receipt image ($distance of 64 bits '
              'differ)',
        ),
      );
    }
  }
  return warnings;
}

/// Other receipts with the same merchant (normalised names equal), date
/// and total. Receipts missing any of the three are never compared.
List<DuplicateWarning> findEconomicDuplicates(
  String receiptId,
  ReceiptFields fields,
  Map<String, ReceiptFields> others,
) {
  final merchant = fields.merchant;
  final date = fields.date;
  final total = fields.total;
  if (merchant == null || date == null || total == null) return const [];
  final key = normaliseMerchant(merchant);
  return [
    for (final entry in others.entries)
      if (entry.key != receiptId &&
          entry.value.merchant != null &&
          normaliseMerchant(entry.value.merchant!) == key &&
          entry.value.date == date &&
          entry.value.total == total)
        DuplicateWarning(
          kind: DuplicateKind.economic,
          otherReceiptId: entry.key,
          detail:
              'Another receipt has the same merchant, date and amount. '
              'Keep both if these were separate purchases.',
        ),
  ];
}
