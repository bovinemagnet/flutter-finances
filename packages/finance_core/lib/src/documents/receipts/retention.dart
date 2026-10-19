import 'package:meta/meta.dart';

import 'document_asset.dart';
import 'receipt.dart';
import 'receipt_link.dart';

/// What deliberately deleting a receipt document removes (REC 08).
///
/// Journals are never part of the plan: removing the document leaves the
/// financial transaction intact. [journalIdsKept] lists the entries that
/// lose their link so the interface can say so.
@immutable
class DocumentDeletionPlan {
  DocumentDeletionPlan({
    required this.receipt,
    required Set<String> assetIds,
    required Set<String> pageIds,
    required Set<String> linkIds,
    required Set<String> journalIdsKept,
  }) : assetIds = Set.unmodifiable(assetIds),
       pageIds = Set.unmodifiable(pageIds),
       linkIds = Set.unmodifiable(linkIds),
       journalIdsKept = Set.unmodifiable(journalIdsKept);

  /// The receipt marked deleted (kept as a tombstone for sync).
  final Receipt receipt;
  final Set<String> assetIds;
  final Set<String> pageIds;
  final Set<String> linkIds;
  final Set<String> journalIdsKept;
}

DocumentDeletionPlan planDocumentDeletion({
  required Receipt receipt,
  required Iterable<ReceiptPage> pages,
  required Iterable<DocumentAsset> assets,
  required Iterable<ReceiptTransactionLink> links,
  required DateTime now,
}) {
  final own = links.where((l) => l.receiptId == receipt.id);
  return DocumentDeletionPlan(
    receipt: receipt.copyWith(deletedAt: now.toUtc()),
    assetIds: {
      for (final a in assets)
        if (a.receiptId == receipt.id) a.id,
    },
    pageIds: {
      for (final p in pages)
        if (p.receiptId == receipt.id) p.id,
    },
    linkIds: {for (final l in own) l.id},
    journalIdsKept: {for (final l in own) l.journalId},
  );
}
