import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';

/// Counts money toward a goal in the Savings plan (BUD 04).
///
/// An allocation is never an expense and never moves money. Moving money is
/// a ledger transfer; when one exists it is referenced by
/// [transferJournalId], which is how allocated savings are distinguished
/// from money actually moved. A negative [amount] releases an allocation.
@immutable
class SavingsAllocation {
  const SavingsAllocation({
    required this.id,
    required this.goalId,
    required this.date,
    required this.amount,
    this.transferJournalId,
    this.note,
  });

  final String id;
  final String goalId;
  final LocalDate date;
  final Money amount;
  final String? transferJournalId;
  final String? note;
}
