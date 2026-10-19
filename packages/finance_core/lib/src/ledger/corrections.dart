import 'package:meta/meta.dart';

import '../ids.dart';
import 'journal.dart';

@immutable
class CorrectionResult {
  const CorrectionResult(this.original, this.reversal, this.replacement);

  /// The original journal, now marked [JournalStatus.reversed].
  final Journal original;
  final Journal reversal;
  final Journal? replacement;

  List<Journal> get journals => [original, reversal, ?replacement];
}

/// Reverses [original] on its own effective date, so the corrected figure
/// applies to the period it always belonged to.
Journal reverseJournal(Journal original, {DateTime? enteredAt}) {
  if (!original.status.inPostedLedger) {
    throw StateError('Only posted journals need a reversal');
  }
  if (original.status == JournalStatus.reversed) {
    throw StateError('Journal ${original.id} is already reversed');
  }
  return Journal(
    id: newId(),
    type: TransactionType.reversal,
    status: JournalStatus.posted,
    effectiveDate: original.effectiveDate,
    enteredAt: enteredAt ?? DateTime.now().toUtc(),
    postings: [for (final p in original.postings) p.negated()],
    accountId: original.accountId,
    counterAccountId: original.counterAccountId,
    amount: original.amount,
    payee: original.payee,
    reversalOf: original.id,
  );
}

/// Applies an ordinary edit to a posted journal as reversal plus replacement
/// (FIN 07). Pass a null [replacement] to void the journal.
CorrectionResult correctJournal(Journal original, Journal? replacement) {
  final reversal = reverseJournal(original);
  final linked = replacement == null
      ? null
      : Journal(
          id: replacement.id,
          type: replacement.type,
          status: replacement.status,
          effectiveDate: replacement.effectiveDate,
          enteredAt: replacement.enteredAt,
          postings: replacement.postings,
          accountId: replacement.accountId,
          counterAccountId: replacement.counterAccountId,
          amount: replacement.amount,
          payee: replacement.payee,
          notes: replacement.notes,
          tags: replacement.tags,
          refundOf: replacement.refundOf ?? original.refundOf,
          replaces: original.id,
        );
  return CorrectionResult(
    original.copyWith(status: JournalStatus.reversed),
    reversal,
    linked,
  );
}
