import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../matching/deduplication.dart';
import '../receipts/document_asset.dart';
import '../receipts/receipt.dart';
import '../receipts/receipt_link.dart';

/// Version of the archive layout and manifest format.
const archiveFormatVersion = 1;

/// Version of the entity JSON inside the archive; matches the sync
/// protocol's schema version.
const archiveSchemaVersion = 1;

/// How effective dates in the archive are to be read (EXP 01).
const archiveEffectiveDateSemantics =
    'Financial effective dates are calendar dates (YYYY-MM-DD) in the '
    'workspace timezone, without a time. Technical timestamps are UTC '
    'instants in ISO 8601.';

enum ArchiveFileRole { data, receiptSource, receiptDerivative, csvView }

/// One file in the archive with its checksum.
@immutable
class ArchiveFile {
  const ArchiveFile({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    required this.role,
    this.contentType,
    this.assetId,
  });

  factory ArchiveFile.fromBytes(
    String path,
    List<int> bytes,
    ArchiveFileRole role, {
    String? contentType,
    String? assetId,
  }) => ArchiveFile(
    path: path,
    sha256: sha256Hex(bytes),
    sizeBytes: bytes.length,
    role: role,
    contentType: contentType,
    assetId: assetId,
  );

  /// Relative path inside the archive, `/` separated.
  final String path;
  final String sha256;
  final int sizeBytes;
  final ArchiveFileRole role;
  final String? contentType;

  /// The document asset stored in this file, for receipt files.
  final String? assetId;
}

/// Which assets and journals belong to a receipt.
@immutable
class ArchiveRelationship {
  ArchiveRelationship({
    required this.receiptId,
    required List<String> assetIds,
    required List<String> journalIds,
  }) : assetIds = List.unmodifiable(assetIds),
       journalIds = List.unmodifiable(journalIds);

  final String receiptId;
  final List<String> assetIds;
  final List<String> journalIds;
}

/// A local change not yet accepted by the server when the archive was
/// made, recorded apart from the accepted state (DATA 03).
@immutable
class PendingLocalChange {
  const PendingLocalChange({
    required this.commandId,
    required this.type,
    required this.entityType,
    required this.entityId,
  });

  final String commandId;
  final String type;
  final String entityType;
  final String entityId;
}

/// The manifest of a portable archive (DATA 01). Encryption of the
/// archive itself belongs to the store.
@immutable
class ArchiveManifest {
  ArchiveManifest({
    required this.schemaVersion,
    required this.createdAt,
    required this.workspaceId,
    required this.currency,
    required this.timezone,
    required List<ArchiveFile> files,
    required Map<String, int> entityCounts,
    required List<ArchiveRelationship> relationships,
    this.formatVersion = archiveFormatVersion,
    this.effectiveDateSemantics = archiveEffectiveDateSemantics,
    this.acceptedRevision,
    this.acceptedCursor,
    List<PendingLocalChange> pendingLocalChanges = const [],
  }) : files = List.unmodifiable(files),
       entityCounts = Map.unmodifiable(entityCounts),
       relationships = List.unmodifiable(relationships),
       pendingLocalChanges = List.unmodifiable(pendingLocalChanges);

  final int formatVersion;
  final int schemaVersion;

  /// When the archive was made (UTC).
  final DateTime createdAt;
  final String workspaceId;
  final Currency currency;

  /// IANA timezone of the workspace, for example `Australia/Sydney`.
  final String timezone;
  final String effectiveDateSemantics;

  /// Last server revision included, for synced workspaces.
  final int? acceptedRevision;

  /// Change feed cursor at export time, for synced workspaces.
  final String? acceptedCursor;
  final List<PendingLocalChange> pendingLocalChanges;
  final List<ArchiveFile> files;

  /// Number of records per entity type, for example `journals`.
  final Map<String, int> entityCounts;
  final List<ArchiveRelationship> relationships;
}

/// Relationships for every receipt: its assets and linked journals, each
/// sorted by id, receipts in id order.
List<ArchiveRelationship> archiveRelationships(
  Iterable<Receipt> receipts,
  Iterable<DocumentAsset> assets,
  Iterable<ReceiptTransactionLink> links,
) {
  final ordered = receipts.toList()..sort((a, b) => a.id.compareTo(b.id));
  return [
    for (final receipt in ordered)
      ArchiveRelationship(
        receiptId: receipt.id,
        assetIds: [
          for (final a in assets)
            if (a.receiptId == receipt.id) a.id,
        ]..sort(),
        journalIds: {
          for (final l in links)
            if (l.receiptId == receipt.id) l.journalId,
        }.toList()..sort(),
      ),
  ];
}

Map<String, Object?> archiveManifestToJson(ArchiveManifest m) => {
  'formatVersion': m.formatVersion,
  'schemaVersion': m.schemaVersion,
  'createdAt': m.createdAt.toUtc().toIso8601String(),
  'workspaceId': m.workspaceId,
  'currency': m.currency.code,
  'currencyExponent': m.currency.exponent,
  'timezone': m.timezone,
  'effectiveDateSemantics': m.effectiveDateSemantics,
  'acceptedRevision': m.acceptedRevision,
  'acceptedCursor': m.acceptedCursor,
  'pendingLocalChanges': [
    for (final c in m.pendingLocalChanges)
      {
        'commandId': c.commandId,
        'type': c.type,
        'entityType': c.entityType,
        'entityId': c.entityId,
      },
  ],
  'files': [
    for (final f in m.files)
      {
        'path': f.path,
        'sha256': f.sha256,
        'sizeBytes': f.sizeBytes,
        'role': f.role.name,
        'contentType': f.contentType,
        'assetId': f.assetId,
      },
  ],
  'entityCounts': {
    for (final key in (m.entityCounts.keys.toList()..sort()))
      key: m.entityCounts[key],
  },
  'relationships': [
    for (final r in m.relationships)
      {
        'receiptId': r.receiptId,
        'assetIds': r.assetIds,
        'journalIds': r.journalIds,
      },
  ],
};

List<Map<String, Object?>> _maps(Object? list) => [
  for (final item in (list as List? ?? const []))
    (item as Map).cast<String, Object?>(),
];

ArchiveManifest archiveManifestFromJson(Map<String, Object?> json) =>
    ArchiveManifest(
      formatVersion: json['formatVersion'] as int,
      schemaVersion: json['schemaVersion'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      workspaceId: json['workspaceId'] as String,
      currency: Currency(
        json['currency'] as String,
        json['currencyExponent'] as int,
      ),
      timezone: json['timezone'] as String,
      effectiveDateSemantics: json['effectiveDateSemantics'] as String,
      acceptedRevision: json['acceptedRevision'] as int?,
      acceptedCursor: json['acceptedCursor'] as String?,
      pendingLocalChanges: [
        for (final c in _maps(json['pendingLocalChanges']))
          PendingLocalChange(
            commandId: c['commandId'] as String,
            type: c['type'] as String,
            entityType: c['entityType'] as String,
            entityId: c['entityId'] as String,
          ),
      ],
      files: [
        for (final f in _maps(json['files']))
          ArchiveFile(
            path: f['path'] as String,
            sha256: f['sha256'] as String,
            sizeBytes: f['sizeBytes'] as int,
            role: ArchiveFileRole.values.byName(f['role'] as String),
            contentType: f['contentType'] as String?,
            assetId: f['assetId'] as String?,
          ),
      ],
      entityCounts: (json['entityCounts'] as Map).cast<String, int>(),
      relationships: [
        for (final r in _maps(json['relationships']))
          ArchiveRelationship(
            receiptId: r['receiptId'] as String,
            assetIds: (r['assetIds'] as List).cast<String>(),
            journalIds: (r['journalIds'] as List).cast<String>(),
          ),
      ],
    );
