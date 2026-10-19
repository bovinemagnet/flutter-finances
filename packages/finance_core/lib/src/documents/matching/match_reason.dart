import 'package:meta/meta.dart';

import '../../time/local_date.dart';

/// Why a candidate was proposed or cannot be linked (MATCH 01).
enum MatchReasonCode {
  sameAmount,
  amountMismatch,
  currencyMismatch,
  alreadyLinked,
  merchantMatches,
  merchantSimilar,
  accountHint,
  sameDay,
  dateNear,

  /// The entry was created from a receipt (MATCH 03).
  receiptEntry,
}

/// A reason with a plain-language message for the interface.
@immutable
class MatchReason {
  const MatchReason(this.code, this.message);

  final MatchReasonCode code;
  final String message;

  @override
  String toString() => message;
}

/// "Same day", "2 days after the receipt", "1 day before the receipt".
MatchReason dateReason(LocalDate reference, LocalDate other, String noun) {
  final days = reference.daysUntil(other);
  if (days == 0) return const MatchReason(MatchReasonCode.sameDay, 'Same day');
  final count = days.abs();
  final unit = count == 1 ? 'day' : 'days';
  return MatchReason(
    MatchReasonCode.dateNear,
    '$count $unit ${days > 0 ? 'after' : 'before'} the $noun',
  );
}
