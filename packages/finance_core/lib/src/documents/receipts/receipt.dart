import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';
import 'receipt_states.dart';

/// Where a receipt came from (REC 01).
enum CaptureSource {
  camera,
  documentScanner,
  photoLibrary,
  shareTarget,
  fileImport,
  paste,
  dragAndDrop,
}

/// The user's decision at review (REC 06).
enum ReviewOutcome { attachedToTransaction, expenseCreated, documentOnly }

/// Receipt field values. On a [Receipt] these are the values the user
/// confirmed; extraction candidates are held separately on an extraction
/// record so that rerunning extraction can never overwrite them (OCR 03).
@immutable
class ReceiptFields {
  const ReceiptFields({
    this.merchant,
    this.date,
    this.total,
    this.tax,
    this.isRefund,
  });

  final String? merchant;
  final LocalDate? date;

  /// The amount paid as a positive magnitude, in the receipt's currency.
  final Money? total;
  final Money? tax;
  final bool? isRefund;

  bool get isEmpty =>
      merchant == null &&
      date == null &&
      total == null &&
      tax == null &&
      isRefund == null;

  /// These fields with every non-null value of [other] laid over them.
  ReceiptFields merge(ReceiptFields other) => ReceiptFields(
    merchant: other.merchant ?? merchant,
    date: other.date ?? date,
    total: other.total ?? total,
    tax: other.tax ?? tax,
    isRefund: other.isRefund ?? isRefund,
  );

  @override
  bool operator ==(Object other) =>
      other is ReceiptFields &&
      other.merchant == merchant &&
      other.date == date &&
      other.total == total &&
      other.tax == tax &&
      other.isRefund == isRefund;

  @override
  int get hashCode => Object.hash(merchant, date, total, tax, isRefund);
}

/// A captured receipt and its review state (REC 03, REC 04).
@immutable
class Receipt {
  Receipt({
    required this.id,
    required this.capturedAt,
    required this.source,
    this.extractionState = ExtractionState.captured,
    this.confirmed = const ReceiptFields(),
    this.latestExtractionId,
    this.outcome,
    this.notes,
    Set<String> tags = const {},
    this.deletedAt,
  }) : tags = Set.unmodifiable(tags);

  final String id;

  /// When the receipt was saved (UTC).
  final DateTime capturedAt;
  final CaptureSource source;
  final ExtractionState extractionState;

  /// Values the user confirmed; never written by extraction.
  final ReceiptFields confirmed;
  final String? latestExtractionId;
  final ReviewOutcome? outcome;
  final String? notes;
  final Set<String> tags;

  /// Set when the user deliberately deleted the document (REC 08).
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  Receipt copyWith({
    ExtractionState? extractionState,
    ReceiptFields? confirmed,
    String? latestExtractionId,
    ReviewOutcome? outcome,
    String? notes,
    Set<String>? tags,
    DateTime? deletedAt,
  }) => Receipt(
    id: id,
    capturedAt: capturedAt,
    source: source,
    extractionState: extractionState ?? this.extractionState,
    confirmed: confirmed ?? this.confirmed,
    latestExtractionId: latestExtractionId ?? this.latestExtractionId,
    outcome: outcome ?? this.outcome,
    notes: notes ?? this.notes,
    tags: tags ?? this.tags,
    deletedAt: deletedAt ?? this.deletedAt,
  );

  Receipt withExtractionEvent(ExtractionEvent event) =>
      copyWith(extractionState: nextExtractionState(extractionState, event));

  /// Records user-confirmed values, keeping earlier confirmations for
  /// fields not supplied.
  Receipt withConfirmedFields(ReceiptFields fields) =>
      copyWith(confirmed: confirmed.merge(fields));
}

/// One page of a receipt. A multi-page PDF source has a page per
/// [sourcePageIndex], all sharing the same [sourceAssetId].
@immutable
class ReceiptPage {
  const ReceiptPage({
    required this.id,
    required this.receiptId,
    required this.pageNumber,
    required this.sourceAssetId,
    this.sourcePageIndex = 0,
    this.derivativeAssetId,
  });

  final String id;
  final String receiptId;

  /// 1-based position within the receipt.
  final int pageNumber;
  final String sourceAssetId;

  /// Zero-based page within the source asset.
  final int sourcePageIndex;

  /// The confirmed readable derivative for this page, when one exists.
  final String? derivativeAssetId;
}
