import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' as store;

import '../platform/image_metadata.dart';
import '../platform/image_tools.dart';
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
  static const fingerprint = 'imageFingerprint';
}

/// Something worth checking about a captured receipt; never blocks saving.
class CaptureWarning {
  const CaptureWarning(this.message, {this.otherReceiptId});
  final String message;
  final String? otherReceiptId;
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
        kind: store.VaultAssetKind.source,
        contentType: result.contentType!.mimeType,
        bytes: bytes,
      );
      if (result.contentType != DocumentContentType.pdf) {
        try {
          final hash = differenceHash(differenceHashMatrix(bytes));
          await _store.upsertEntity(ReceiptEntityTypes.fingerprint, asset.id, {
            'id': asset.id,
            'receiptId': receiptId,
            'assetId': asset.id,
            'dHash': hash,
          });
        } on FormatException {
          // Images the decoder cannot read are still kept.
        }
      }
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
          dateConvention: state.dateConvention,
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

  /// Quality and duplicate warnings for a saved receipt (REC 02, MATCH 02).
  Future<List<CaptureWarning>> warningsFor(String receiptId) async {
    final warnings = <CaptureWarning>[];
    final own = _store.vault.assetsFor(ReceiptEntityTypes.receipt, receiptId);
    final others = [
      for (final r in receipts())
        if (r.id != receiptId)
          for (final a in _store.vault.assetsFor(
            ReceiptEntityTypes.receipt,
            r.id,
          ))
            (r.id, a),
    ];
    for (final asset in own) {
      for (final (otherId, other) in others) {
        if (other.sha256 == asset.sha256) {
          warnings.add(
            CaptureWarning(
              'This exact file is already saved as another receipt',
              otherReceiptId: otherId,
            ),
          );
        }
      }
      if (asset.kind == store.VaultAssetKind.source &&
          asset.contentType != 'application/pdf') {
        final quality = assessQuality(await _store.vault.readAsset(asset.id));
        if (quality.likelyBlurred) {
          warnings.add(
            const CaptureWarning(
              'The photo looks blurred; check the details are readable',
            ),
          );
        }
        if (quality.lowResolution) {
          warnings.add(
            const CaptureWarning(
              'The photo is small; the text may be hard to read',
            ),
          );
        }
      }
    }
    final fingerprints = [
      for (final r in _store.entities(ReceiptEntityTypes.fingerprint))
        if (!r.deleted)
          ImageFingerprint(
            receiptId: r.json['receiptId'] as String,
            assetId: r.json['assetId'] as String,
            dHash: r.json['dHash'] as String,
          ),
    ];
    final live = {for (final r in receipts()) r.id};
    for (final mine in fingerprints.where((f) => f.receiptId == receiptId)) {
      for (final warning in findSimilarImages(
        mine,
        fingerprints.where(
          (f) => f.receiptId != receiptId && live.contains(f.receiptId),
        ),
      )) {
        if (warnings.any((w) => w.otherReceiptId == warning.otherReceiptId)) {
          continue;
        }
        warnings.add(
          CaptureWarning(
            'This looks like a photo of a receipt already saved',
            otherReceiptId: warning.otherReceiptId,
          ),
        );
      }
    }
    return warnings;
  }

  /// Saves an edited, readable copy of a page alongside its original
  /// (REC 02); the source stays exactly as captured.
  Future<void> saveReadableCopy(ReceiptPage page, ImageEdits edits) async {
    final source = await _store.vault.readAsset(page.sourceAssetId);
    final derivative = await _store.vault.saveAsset(
      ownerType: ReceiptEntityTypes.receipt,
      ownerId: page.receiptId,
      kind: store.VaultAssetKind.derivative,
      contentType: 'image/jpeg',
      bytes: applyEdits(source, edits),
    );
    final previous = page.derivativeAssetId;
    final updated = ReceiptPage(
      id: page.id,
      receiptId: page.receiptId,
      pageNumber: page.pageNumber,
      sourceAssetId: page.sourceAssetId,
      sourcePageIndex: page.sourcePageIndex,
      derivativeAssetId: derivative.id,
    );
    await _store.upsertEntity(
      ReceiptEntityTypes.page,
      page.id,
      receiptPageToJson(updated),
    );
    if (previous != null) await _store.vault.deleteAsset(previous);
    state.refresh();
  }

  /// Splits a multi-receipt document manually (REC 05): each group of page
  /// numbers after the first becomes a new receipt sharing the same source
  /// file. Returns the new receipts.
  Future<List<Receipt>> splitPages(
    String receiptId,
    List<List<int>> groups,
  ) async {
    final pages = {for (final p in pagesFor(receiptId)) p.pageNumber: p};
    final used = groups.expand((g) => g).toList();
    if (used.toSet().length != used.length || !used.every(pages.containsKey)) {
      throw ArgumentError('Each page must be assigned to exactly one receipt');
    }
    final original = receipt(receiptId)!;
    final created = <Receipt>[];
    for (final group in groups.skip(1)) {
      final newReceipt = Receipt(
        id: newId(),
        capturedAt: original.capturedAt,
        source: original.source,
      );
      for (final (index, number) in group.indexed) {
        final page = pages[number]!;
        final moved = ReceiptPage(
          id: page.id,
          receiptId: newReceipt.id,
          pageNumber: index + 1,
          sourceAssetId: page.sourceAssetId,
          sourcePageIndex: page.sourcePageIndex,
          derivativeAssetId: page.derivativeAssetId,
        );
        await _store.upsertEntity(
          ReceiptEntityTypes.page,
          page.id,
          receiptPageToJson(moved),
        );
      }
      await _putReceipt(newReceipt);
      created.add(newReceipt);
    }
    for (final (index, number) in groups.first.indexed) {
      final page = pages[number]!;
      if (page.pageNumber == index + 1) continue;
      final renumbered = ReceiptPage(
        id: page.id,
        receiptId: receiptId,
        pageNumber: index + 1,
        sourceAssetId: page.sourceAssetId,
        sourcePageIndex: page.sourcePageIndex,
        derivativeAssetId: page.derivativeAssetId,
      );
      await _store.upsertEntity(
        ReceiptEntityTypes.page,
        page.id,
        receiptPageToJson(renumbered),
      );
    }
    state.refresh();
    return created;
  }

  /// Writes every receipt's original files into [directory] with a
  /// `manifest.json` describing fields, links and SHA-256 hashes (EXP 01).
  /// Originals only on the server are listed as not exported.
  Future<int> exportOriginals(Directory directory) async {
    await directory.create(recursive: true);
    final entries = <Map<String, Object?>>[];
    var written = 0;
    for (final receipt in receipts()) {
      final extraction = extractionFor(receipt);
      final fields =
          extraction?.suggested.merge(receipt.confirmed) ?? receipt.confirmed;
      final files = <Map<String, Object?>>[];
      for (final asset in _store.vault.assetsFor(
        ReceiptEntityTypes.receipt,
        receipt.id,
      )) {
        if (asset.kind != store.VaultAssetKind.source) continue;
        final extension = switch (asset.contentType) {
          'image/png' => 'png',
          'image/heic' || 'image/heif' => 'heic',
          'application/pdf' => 'pdf',
          _ => 'jpg',
        };
        final name = '${receipt.id}-${files.length + 1}.$extension';
        if (asset.localState != store.AssetLocalState.present) {
          files.add({
            'file': null,
            'sha256': asset.sha256,
            'note': 'stored only on the server',
          });
          continue;
        }
        await File('${directory.path}/$name')
            .writeAsBytes(await _store.vault.readAsset(asset.id), flush: true);
        files.add({
          'file': name,
          'sha256': asset.sha256,
          'contentType': asset.contentType,
        });
        written++;
      }
      entries.add({
        'receiptId': receipt.id,
        'capturedAt': receipt.capturedAt.toIso8601String(),
        'merchant': fields.merchant,
        'date': fields.date?.toString(),
        'totalMinor': fields.total?.minor,
        'taxMinor': fields.tax?.minor,
        'currency': state.currency.code,
        'linkedJournalIds': [for (final l in linksFor(receipt.id)) l.journalId],
        'files': files,
      });
    }
    await File('${directory.path}/manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'finance.receipts',
        'formatVersion': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'receipts': entries,
      }),
    );
    return written;
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
                  kind: a.kind == store.VaultAssetKind.source
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
