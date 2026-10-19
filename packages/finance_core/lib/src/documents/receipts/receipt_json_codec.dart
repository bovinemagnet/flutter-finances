import '../../money/money.dart';
import '../../time/local_date.dart';
import '../validation/content_type.dart';
import 'document_asset.dart';
import 'receipt.dart';
import 'receipt_link.dart';
import 'receipt_states.dart';

/// JSON formats for receipt entities, shared with the server. Money is in
/// minor units; instants are ISO 8601 UTC; dates are `YYYY-MM-DD`.

String? _instant(DateTime? value) => value?.toUtc().toIso8601String();

DateTime? _parseInstant(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

LocalDate? _date(Object? value) =>
    value == null ? null : LocalDate.parse(value as String);

/// Receipt fields carry their own currency because a receipt may be in a
/// currency other than the workspace's.
Map<String, Object?> receiptFieldsToJson(ReceiptFields fields) {
  final currency = (fields.total ?? fields.tax)?.currency;
  return {
    'merchant': fields.merchant,
    'date': fields.date?.toString(),
    'totalMinor': fields.total?.minor,
    'taxMinor': fields.tax?.minor,
    'currency': currency?.code,
    'currencyExponent': currency?.exponent,
    'isRefund': fields.isRefund,
  };
}

ReceiptFields receiptFieldsFromJson(Map<String, Object?> json) {
  final code = json['currency'] as String?;
  final currency = code == null
      ? null
      : Currency(code, json['currencyExponent'] as int? ?? 2);
  Money? money(Object? minor) =>
      minor == null ? null : Money(minor as int, currency!);
  return ReceiptFields(
    merchant: json['merchant'] as String?,
    date: _date(json['date']),
    total: money(json['totalMinor']),
    tax: money(json['taxMinor']),
    isRefund: json['isRefund'] as bool?,
  );
}

Map<String, Object?> receiptToJson(Receipt receipt) => {
  'id': receipt.id,
  'capturedAt': _instant(receipt.capturedAt),
  'source': receipt.source.name,
  'extractionState': receipt.extractionState.name,
  'confirmed': receiptFieldsToJson(receipt.confirmed),
  'latestExtractionId': receipt.latestExtractionId,
  'outcome': receipt.outcome?.name,
  'notes': receipt.notes,
  'tags': receipt.tags.toList()..sort(),
  'deletedAt': _instant(receipt.deletedAt),
};

Receipt receiptFromJson(Map<String, Object?> json) => Receipt(
  id: json['id'] as String,
  capturedAt: _parseInstant(json['capturedAt'])!,
  source: CaptureSource.values.byName(json['source'] as String),
  extractionState: ExtractionState.values.byName(
    json['extractionState'] as String,
  ),
  confirmed: json['confirmed'] == null
      ? const ReceiptFields()
      : receiptFieldsFromJson(
          (json['confirmed'] as Map).cast<String, Object?>(),
        ),
  latestExtractionId: json['latestExtractionId'] as String?,
  outcome: json['outcome'] == null
      ? null
      : ReviewOutcome.values.byName(json['outcome'] as String),
  notes: json['notes'] as String?,
  tags: {...(json['tags'] as List? ?? const []).cast<String>()},
  deletedAt: _parseInstant(json['deletedAt']),
);

Map<String, Object?> receiptPageToJson(ReceiptPage page) => {
  'id': page.id,
  'receiptId': page.receiptId,
  'pageNumber': page.pageNumber,
  'sourceAssetId': page.sourceAssetId,
  'sourcePageIndex': page.sourcePageIndex,
  'derivativeAssetId': page.derivativeAssetId,
};

ReceiptPage receiptPageFromJson(Map<String, Object?> json) => ReceiptPage(
  id: json['id'] as String,
  receiptId: json['receiptId'] as String,
  pageNumber: json['pageNumber'] as int,
  sourceAssetId: json['sourceAssetId'] as String,
  sourcePageIndex: json['sourcePageIndex'] as int? ?? 0,
  derivativeAssetId: json['derivativeAssetId'] as String?,
);

/// [includeLocalState] adds `presentLocally`, which describes this device
/// only; leave it out of sync payloads.
Map<String, Object?> documentAssetToJson(
  DocumentAsset asset, {
  bool includeLocalState = true,
}) => {
  'id': asset.id,
  'receiptId': asset.receiptId,
  'kind': asset.kind.name,
  'contentType': asset.contentType.mimeType,
  'sha256': asset.sha256,
  'sizeBytes': asset.sizeBytes,
  'pageCount': asset.pageCount,
  'createdAt': _instant(asset.createdAt),
  'uploadState': asset.uploadState.name,
  'cloudCopyConfirmed': asset.cloudCopyConfirmed,
  if (includeLocalState) 'presentLocally': asset.presentLocally,
};

/// A missing `presentLocally` (a synced record) reads as not on device.
DocumentAsset documentAssetFromJson(Map<String, Object?> json) => DocumentAsset(
  id: json['id'] as String,
  receiptId: json['receiptId'] as String,
  kind: AssetKind.values.byName(json['kind'] as String),
  contentType: DocumentContentType.fromMimeType(json['contentType'] as String),
  sha256: json['sha256'] as String,
  sizeBytes: json['sizeBytes'] as int,
  pageCount: json['pageCount'] as int,
  createdAt: _parseInstant(json['createdAt'])!,
  uploadState: UploadState.values.byName(json['uploadState'] as String),
  cloudCopyConfirmed: json['cloudCopyConfirmed'] as bool? ?? false,
  presentLocally: json['presentLocally'] as bool? ?? false,
);

Map<String, Object?> receiptLinkToJson(ReceiptTransactionLink link) => {
  'id': link.id,
  'receiptId': link.receiptId,
  'journalId': link.journalId,
  'allocatedMinor': link.allocated.minor,
  'currency': link.allocated.currency.code,
  'confirmedAt': _instant(link.confirmedAt),
};

/// Reads a link in the workspace [currency]; another currency is rejected.
ReceiptTransactionLink receiptLinkFromJson(
  Map<String, Object?> json,
  Currency currency,
) {
  final code = json['currency'] as String?;
  if (code != null && code != currency.code) {
    throw CurrencyMismatchException(
      currency,
      Currency(code, currency.exponent),
    );
  }
  return ReceiptTransactionLink(
    id: json['id'] as String,
    receiptId: json['receiptId'] as String,
    journalId: json['journalId'] as String,
    allocated: Money(json['allocatedMinor'] as int, currency),
    confirmedAt: _parseInstant(json['confirmedAt'])!,
  );
}
