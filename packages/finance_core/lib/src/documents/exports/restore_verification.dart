import 'package:meta/meta.dart';

import '../../ledger/journal.dart';
import '../matching/deduplication.dart';
import 'archive_manifest.dart';

enum RestoreIssueCode {
  formatUnsupported('FORMAT_UNSUPPORTED'),
  schemaUnsupported('SCHEMA_UNSUPPORTED'),
  missingFile('MISSING_FILE'),
  sizeMismatch('SIZE_MISMATCH'),
  hashMismatch('HASH_MISMATCH'),
  unexpectedFile('UNEXPECTED_FILE'),
  unbalancedJournal('UNBALANCED_JOURNAL'),
  currencyMismatch('CURRENCY_MISMATCH'),
  countMismatch('COUNT_MISMATCH'),
  missingAsset('MISSING_ASSET'),
  danglingRelationship('DANGLING_RELATIONSHIP');

  const RestoreIssueCode(this.code);
  final String code;
}

enum RestoreSeverity { error, warning }

@immutable
class RestoreIssue {
  const RestoreIssue(
    this.code,
    this.message, {
    this.subject,
    this.severity = RestoreSeverity.error,
  });

  final RestoreIssueCode code;
  final String message;

  /// The file path or record id concerned.
  final String? subject;
  final RestoreSeverity severity;

  @override
  String toString() => '${code.code} ${subject ?? ''}: $message';
}

/// What a restore would bring in, shown before anything is applied
/// (DATA 03).
@immutable
class RestorePreview {
  RestorePreview({
    required this.manifest,
    required List<RestoreIssue> issues,
    required Map<String, ({int expected, int actual})> counts,
    required this.verifiedFiles,
  }) : issues = List.unmodifiable(issues),
       counts = Map.unmodifiable(counts);

  final ArchiveManifest manifest;
  final List<RestoreIssue> issues;

  /// Expected (manifest) and actual record counts per entity type.
  final Map<String, ({int expected, int actual})> counts;

  /// Files whose size and checksum matched.
  final int verifiedFiles;

  /// Local changes that were not yet accepted when exported; they are
  /// shown separately and never replayed into a live workspace.
  int get pendingLocalChanges => manifest.pendingLocalChanges.length;

  bool get canRestore =>
      issues.every((i) => i.severity != RestoreSeverity.error);
}

/// Verifies an unpacked archive before it is restored into an isolated
/// workspace (DATA 03, A16).
///
/// Checks, in order: format and schema compatibility; every manifest file
/// is present with the recorded size and SHA-256 (extra files are a
/// warning); every journal balances (`validatePostings`) in the manifest
/// currency; record counts equal the manifest (`journals` defaults to the
/// number of [journals] when [actualCounts] lacks it); every receipt
/// relationship points at stored assets and restored journals.
RestorePreview verifyArchive({
  required ArchiveManifest manifest,
  required Map<String, List<int>> files,
  required List<Journal> journals,
  required Map<String, int> actualCounts,
  int minimumSchemaVersion = 1,
  int supportedSchemaVersion = archiveSchemaVersion,
}) {
  final issues = <RestoreIssue>[];
  if (manifest.formatVersion != archiveFormatVersion) {
    issues.add(
      RestoreIssue(
        RestoreIssueCode.formatUnsupported,
        'Archive format ${manifest.formatVersion} is not supported; update '
        'the app and try again',
      ),
    );
  }
  if (manifest.schemaVersion < minimumSchemaVersion ||
      manifest.schemaVersion > supportedSchemaVersion) {
    issues.add(
      RestoreIssue(
        RestoreIssueCode.schemaUnsupported,
        'Data schema ${manifest.schemaVersion} is outside the supported '
        'range $minimumSchemaVersion to $supportedSchemaVersion',
      ),
    );
  }

  var verified = 0;
  final presentAssets = <String>{};
  final listed = <String>{};
  for (final file in manifest.files) {
    listed.add(file.path);
    final bytes = files[file.path];
    if (bytes == null) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.missingFile,
          'The file is missing from the archive',
          subject: file.path,
        ),
      );
      continue;
    }
    if (bytes.length != file.sizeBytes) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.sizeMismatch,
          'Expected ${file.sizeBytes} bytes, found ${bytes.length}',
          subject: file.path,
        ),
      );
      continue;
    }
    if (sha256Hex(bytes) != file.sha256.toLowerCase()) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.hashMismatch,
          'The checksum does not match; the file is damaged or altered',
          subject: file.path,
        ),
      );
      continue;
    }
    verified++;
    if (file.assetId != null) presentAssets.add(file.assetId!);
  }
  for (final path in files.keys) {
    if (!listed.contains(path)) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.unexpectedFile,
          'The file is not in the manifest and will be ignored',
          subject: path,
          severity: RestoreSeverity.warning,
        ),
      );
    }
  }

  for (final journal in journals) {
    final errors = validatePostings(journal.postings);
    if (errors.isNotEmpty) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.unbalancedJournal,
          'Journal fails validation: ${errors.map((e) => e.code).join(', ')}',
          subject: journal.id,
        ),
      );
    } else if (journal.postings.first.amount.currency != manifest.currency) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.currencyMismatch,
          'Journal is not in ${manifest.currency}',
          subject: journal.id,
        ),
      );
    }
  }

  final counts = <String, ({int expected, int actual})>{};
  final actual = {'journals': journals.length, ...actualCounts};
  for (final entry in manifest.entityCounts.entries) {
    final found = actual[entry.key] ?? 0;
    counts[entry.key] = (expected: entry.value, actual: found);
    if (found != entry.value) {
      issues.add(
        RestoreIssue(
          RestoreIssueCode.countMismatch,
          'Expected ${entry.value} ${entry.key}, found $found',
          subject: entry.key,
        ),
      );
    }
  }

  final journalIds = {for (final j in journals) j.id};
  for (final relationship in manifest.relationships) {
    for (final assetId in relationship.assetIds) {
      if (!presentAssets.contains(assetId)) {
        issues.add(
          RestoreIssue(
            RestoreIssueCode.missingAsset,
            'Receipt ${relationship.receiptId} has no verified file for '
            'asset $assetId',
            subject: assetId,
          ),
        );
      }
    }
    for (final journalId in relationship.journalIds) {
      if (!journalIds.contains(journalId)) {
        issues.add(
          RestoreIssue(
            RestoreIssueCode.danglingRelationship,
            'Receipt ${relationship.receiptId} is linked to journal '
            '$journalId, which is not in the archive',
            subject: journalId,
          ),
        );
      }
    }
  }
  return RestorePreview(
    manifest: manifest,
    issues: issues,
    counts: counts,
    verifiedFiles: verified,
  );
}
