import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../../time/local_date.dart';

/// Whether the source reported the transaction as pending or posted.
enum SourceStatus { pending, posted }

/// What happened to a source record when its batch was committed.
enum SourceDecision {
  /// A new journal was created from it.
  created,

  /// It was confirmed as evidence for an existing journal (MATCH 03).
  matchedExisting,

  /// It was already imported (same fingerprint); nothing was created.
  duplicate,

  /// The user chose not to import it.
  skipped,
}

/// One imported row kept as evidence, separate from journals (IMP 02,
/// IMP 03). Corrections to the journal never erase where it came from.
@immutable
class SourceRecord {
  SourceRecord({
    required this.id,
    required this.batchId,
    required this.accountId,
    required this.rowNumber,
    required this.fingerprint,
    required List<String> raw,
    required this.date,
    required this.amount,
    required this.description,
    required this.decision,
    this.reference,
    this.pendingReference,
    this.status = SourceStatus.posted,
    this.journalId,
    this.rolledBack = false,
  }) : raw = List.unmodifiable(raw);

  final String id;
  final String batchId;
  final String accountId;

  /// 1-based record number in the source file.
  final int rowNumber;

  /// See `assignFingerprints`.
  final String fingerprint;

  /// The raw fields exactly as read.
  final List<String> raw;
  final LocalDate date;

  /// Signed from the account's point of view; negative is money leaving.
  final Money amount;
  final String description;

  /// Bank or provider identifier of this record.
  final String? reference;

  /// Provider-supplied identifier of the pending record this posted record
  /// replaces, when the provider reports the relationship.
  final String? pendingReference;
  final SourceStatus status;
  final SourceDecision decision;

  /// The journal created from, or matched to, this record.
  final String? journalId;

  /// True once the batch was rolled back; the evidence is kept.
  final bool rolledBack;

  SourceRecord copyWith({
    SourceDecision? decision,
    String? journalId,
    bool? rolledBack,
  }) => SourceRecord(
    id: id,
    batchId: batchId,
    accountId: accountId,
    rowNumber: rowNumber,
    fingerprint: fingerprint,
    raw: raw,
    date: date,
    amount: amount,
    description: description,
    decision: decision ?? this.decision,
    reference: reference,
    pendingReference: pendingReference,
    status: status,
    journalId: journalId ?? this.journalId,
    rolledBack: rolledBack ?? this.rolledBack,
  );
}
