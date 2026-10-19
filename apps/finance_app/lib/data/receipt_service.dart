import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' as store;

import '../platform/image_metadata.dart';
import '../platform/services.dart';
import '../platform/text_recognition.dart';
import 'app_state.dart';

class ReceiptRejectedException implements Exception {
  ReceiptRejectedException(this.messages);
  final List<String> messages;

  @override
  String toString() => messages.join('\n');
}

abstract final class ReceiptEntityTypes {
  static const receipt = 'receipt';
  static const page = 'receiptPage';
  static const link = 'receiptLink';
  static const extraction = 'extraction';
}

/// Receipt capture, extraction, review and retention (section 7).
///
/// Files are written to the encrypted vault and committed before metadata,
/// and only then is a receipt reported saved (REC 03). Extraction and review
/// never post an expense without an explicit decision (REC 06, OCR 04).
class ReceiptService {
  ReceiptService(this.state);

  final AppState state;
  store.FinanceStore get _store => state.store;

  List<T> _all<T>(String type, T Function(Map<String, Object?>) decode) => [
    for (final r in _store.entities(type))
      if (!r.deleted) decode(r.json),
  ];

  List<Receipt> receipts({bool includeDeleted = false}) => [
    for (final r in _all(ReceiptEntityTypes.receipt, receiptFromJson))
      if (includeDeleted || r.deletedAt == null) r,
  ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));

  Receipt? receipt(String id) {
    final record = _store.entity(ReceiptEntityTypes.receipt, id);
    return record == null || record.deleted
        ? null
        : receiptFromJson(record.json);
  }

  List<ReceiptPage> pagesFor(String receiptId) => [
    for (final p in _all(ReceiptEntityTypes.page, receiptPageFromJson))
      if (p.receiptId == receiptId) p,
  ]..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

  List<ReceiptTransactionLink> get links => _all(
    ReceiptEntityTypes.link,
    (j) => receiptLinkFromJson(j, state.currency),
  );

  List<ReceiptTransactionLink> linksFor(String receiptId) =>
      links.where((l) => l.receiptId == receiptId).toList();

  /// Journals that have at least one receipt, for reports and insights.
  Set<String> get receiptJournalIds => {for (final l in links) l.journalId};

  Extraction? extractionFor(Receipt receipt) {
    final id = receipt.latestExtractionId;
    if (id == null) return null;
    final record = _store.entity(ReceiptEntityTypes.extraction, id);
    return record == null ? null : extractionFromJson(record.json);
  }

  Future<Uint8List> readPage(ReceiptPage page) =>
      _store.vault.readAsset(page.derivativeAssetId ?? page.sourceAssetId);

  Future<void> _putReceipt(Receipt receipt) => _store.upsertEntity(
    ReceiptEntityTypes.receipt,
    receipt.id,
    receiptToJson(receipt),
  );

  /// Validates and durably saves captured files as one receipt.
  Future<Receipt> capture(List<CapturedFile> files) async {
    if (files.isEmpty) throw ReceiptRejectedException(['Nothing was captured']);
    final problems = <String>[];
    final accepted = <(CapturedFile, ContentValidationResult)>[];
    var pageCount = 0;
    for (final file in files) {
      final result = validateDocument(file.bytes, fileName: file.fileName);
      if (!result.isAccepted) {
        problems.addAll(result.errors.map((e) => e.message));
      } else {
        accepted.add((file, result));
        pageCount += result.pageCount ?? 1;
      }
    }
    final pageIssue = checkReceiptPageLimit(
      existingPages: 0,
      addedPages: pageCount,
    );
    if (pageIssue != null) problems.add(pageIssue.message);
    if (problems.isNotEmpty) throw ReceiptRejectedException(problems);

    final receiptId = newId();
    final pages = <ReceiptPage>[];
    for (final (file, result) in accepted) {
      // New copies from the camera or clipboard lose location metadata;
      // imported files are preserved exactly as received (REC 02).
      final isNewCopy =
          file.source == CaptureSource.camera ||
          file.source == CaptureSource.documentScanner ||
          file.source == CaptureSource.paste;
      final bytes = isNewCopy ? stripImageMetadata(file.bytes) : file.bytes;
      final asset = await _store.vault.saveAsset(
        ownerType: ReceiptEntityTypes.receipt,
        ownerId: receiptId,
        kind: store.AssetKind.source,
        contentType: result.contentType!.mimeType,
        bytes: bytes,
      );
      final count = result.pageCount ?? 1;
      for (var index = 0; index < count; index++) {
        pages.add(
          ReceiptPage(
            id: newId(),
            receiptId: receiptId,
            pageNumber: pages.length + 1,
            sourceAssetId: asset.id,
            sourcePageIndex: index,
          ),
        );
      }
    }
    for (final page in pages) {
      await _store.upsertEntity(
        ReceiptEntityTypes.page,
        page.id,
        receiptPageToJson(page),
      );
    }
    final receipt = Receipt(
      id: receiptId,
      capturedAt: DateTime.now().toUtc(),
      source: files.first.source,
    );
    await _putReceipt(receipt);
    state.refresh();
    return receipt;
  }

  /// Runs text recognition and parsing; failure keeps the document and
  /// leaves retry and manual entry available (REC 04).
  Future<Receipt> extract(String receiptId, TextRecogniser recogniser) async {
    var current = receipt(receiptId)!;
    if (current.extractionState == ExtractionState.extractionFailed ||
        current.extractionState == ExtractionState.captured) {
      current = current.withExtractionEvent(
        current.extractionState == ExtractionState.extractionFailed
            ? ExtractionEvent.retry
            : ExtractionEvent.queue,
      );
    }
    current = current.withExtractionEvent(ExtractionEvent.start);
    await _putReceipt(current);
    try {
      final images = <Uint8List>[];
      final seen = <String>{};
      for (final page in pagesFor(receiptId)) {
        if (!seen.add(page.sourceAssetId)) continue;
        final record = _store.vault.asset(page.sourceAssetId);
        if (record == null || record.contentType == 'application/pdf') continue;
        images.add(await readPage(page));
      }
      if (images.isEmpty) {
        throw const TextRecognitionException(
          'Text is not read from PDF receipts on this device; enter the details',
        );
      }
      final ocr = await recogniser.recognise(images);
      final extraction = parseReceipt(
        ocr,
        id: newId(),
        receiptId: receiptId,
        createdAt: DateTime.now().toUtc(),
        settings: ParserSettings(
          workspaceCurrency: state.currency,
          referenceDate: state.today(),
        ),
      );
      await _store.upsertEntity(
        ReceiptEntityTypes.extraction,
        extraction.id,
        extractionToJson(extraction),
      );
      current = current
          .withExtractionEvent(ExtractionEvent.succeed)
          .copyWith(latestExtractionId: extraction.id);
    } on Exception {
      current = current.withExtractionEvent(ExtractionEvent.fail);
    }
    await _putReceipt(current);
    state.refresh();
    return current;
  }

  /// Ranked candidate transactions for a receipt (MATCH 01).
  List<MatchCandidate> candidates(
    ReceiptFields fields, {
    String? accountHint,
  }) => rankMatchCandidates(
    fields,
    state.ledger.journals,
    accountHint: accountHint,
    existingLinks: links,
  );

  /// Applies the user's review decision. Creating an expense posts the
  /// confirmed draft; attaching only records a link (A07).
  Future<Receipt> review(
    String receiptId,
    ReceiptFields confirmed,
    ReviewDecision decision,
  ) async {
    final current = receipt(receiptId)!;
    final result = reviewReceipt(
      receipt: current.extractionState == ExtractionState.reviewed
          ? current
          : _readyForReview(current),
      confirmed: confirmed,
      decision: decision,
      chart: state.chart,
      existingLinks: links,
      now: DateTime.now().toUtc(),
    );
    if (result.draft != null) await state.post(result.draft!);
    if (result.link != null) {
      await _store.upsertEntity(
        ReceiptEntityTypes.link,
        result.link!.id,
        receiptLinkToJson(result.link!),
      );
    }
    await _putReceipt(result.receipt);
    state.refresh();
    return result.receipt;
  }

  Receipt _readyForReview(Receipt receipt) {
    var r = receipt;
    if (r.extractionState == ExtractionState.captured) {
      r = r.withExtractionEvent(ExtractionEvent.queue);
    }
    if (r.extractionState == ExtractionState.extractionQueued) {
      r = r.withExtractionEvent(ExtractionEvent.start);
    }
    if (r.extractionState == ExtractionState.extracting) {
      r = r.withExtractionEvent(ExtractionEvent.fail);
    }
    return r;
  }

  /// Removes a link but keeps the document (REC 08).
  Future<void> unlink(ReceiptTransactionLink link) async {
    await _store.deleteEntity(ReceiptEntityTypes.link, link.id);
    state.refresh();
  }

  /// Deletes the document deliberately; linked transactions are kept.
  Future<void> deleteDocument(String receiptId) async {
    final current = receipt(receiptId)!;
    final pages = pagesFor(receiptId);
    final plan = planDocumentDeletion(
      receipt: current,
      pages: pages,
      assets: const [],
      links: links,
      now: DateTime.now(),
    );
    for (final id in plan.linkIds) {
      await _store.deleteEntity(ReceiptEntityTypes.link, id);
    }
    for (final page in pages) {
      await _store.deleteEntity(ReceiptEntityTypes.page, page.id);
    }
    for (final asset in _store.vault.assetsFor(
      ReceiptEntityTypes.receipt,
      receiptId,
      includePreviews: true,
    )) {
      await _store.vault.deleteAsset(asset.id);
    }
    await _putReceipt(plan.receipt);
    state.refresh();
  }

  List<ReceiptSearchEntry> _entries() {
    final allLinks = links;
    return [
      for (final r in receipts())
        () {
          final extraction = extractionFor(r);
          return ReceiptSearchEntry(
            receipt: r,
            suggested: extraction?.suggested ?? const ReceiptFields(),
            extractedText: extraction?.ocr.lines.map((l) => l.text).join('\n'),
            assets: [
              for (final a in _store.vault.assetsFor(
                ReceiptEntityTypes.receipt,
                r.id,
              ))
                DocumentAsset(
                  id: a.id,
                  receiptId: r.id,
                  kind: a.kind == store.AssetKind.source
                      ? AssetKind.source
                      : AssetKind.readableDerivative,
                  contentType: DocumentContentType.fromMimeType(a.contentType),
                  sha256: a.sha256,
                  sizeBytes: a.sizeBytes,
                  pageCount: 1,
                  createdAt: a.createdAt,
                  presentLocally: a.localState == store.AssetLocalState.present,
                ),
            ],
            links: allLinks.where((l) => l.receiptId == r.id),
          );
        }(),
    ];
  }

  List<Receipt> search(ReceiptQuery query) => [
    for (final e in searchReceipts(_entries(), query)) e.receipt,
  ];
}
