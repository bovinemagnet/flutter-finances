import 'package:meta/meta.dart';

import '../ledger/journal.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'schedules.dart';

/// Links an occurrence to the journal that actually paid (or received) it
/// (PLAN 02). Several links record partial payments. [settles] marks the
/// occurrence paid even when the amount differs from the expected amount.
@immutable
class OccurrencePayment {
  const OccurrencePayment({
    required this.id,
    required this.scheduleId,
    required this.occurrenceDate,
    required this.journalId,
    required this.amount,
    this.settles = false,
  });

  final String id;
  final String scheduleId;

  /// The occurrence's original date in its series.
  final LocalDate occurrenceDate;
  final String journalId;
  final Money amount;
  final bool settles;
}

enum OccurrenceStatus {
  /// Due after today.
  upcoming,

  /// Due today.
  due,

  /// Paid in full, or settled with a changed amount.
  paid,

  /// Some money linked; the rest is outstanding.
  partiallyPaid,

  /// Past due with account data current to the due date and no payment.
  unpaid,

  /// Past due, but the account data is stale or missing, so a missing link
  /// does not prove the bill is unpaid.
  unknown,

  /// Skipped by a "this occurrence" edit.
  skipped,
}

/// Payment state of one occurrence.
@immutable
class OccurrenceState {
  OccurrenceState({
    required this.occurrence,
    required this.status,
    required this.paid,
    required List<OccurrencePayment> payments,
  }) : payments = List.unmodifiable(payments);

  final ScheduledOccurrence occurrence;
  final OccurrenceStatus status;

  /// Total of counted links.
  final Money paid;
  final List<OccurrencePayment> payments;

  Money get expected => occurrence.amount;

  /// Paid less expected; non-zero shows a changed amount.
  Money get difference => paid - expected;

  /// Still expected; zero once paid, settled or skipped.
  Money get outstanding {
    final zero = Money.zero(expected.currency);
    if (status == OccurrenceStatus.paid || status == OccurrenceStatus.skipped) {
      return zero;
    }
    final left = expected - paid;
    return left.isNegative ? zero : left;
  }

  List<String> get journalIds => [for (final p in payments) p.journalId];
}

/// Works out an occurrence's status. Links count only when their journal is
/// posted or pending; drafts, reversed and unknown journals are ignored.
/// [accountDataAsOf] is the date the paying account's data is known to be
/// complete to (last import or reconciliation); without it a missed date is
/// [OccurrenceStatus.unknown].
OccurrenceState assessOccurrence(
  ScheduledOccurrence occurrence, {
  Iterable<OccurrencePayment> payments = const [],
  required Map<String, JournalStatus> journalStatuses,
  required LocalDate today,
  LocalDate? accountDataAsOf,
}) {
  final counted = [
    for (final p in payments)
      if (p.scheduleId == occurrence.scheduleId &&
          p.occurrenceDate == occurrence.originalDate &&
          (journalStatuses[p.journalId] == JournalStatus.posted ||
              journalStatuses[p.journalId] == JournalStatus.pending))
        p,
  ];
  final paid = counted.fold(
    Money.zero(occurrence.amount.currency),
    (sum, p) => sum + p.amount,
  );
  final due = occurrence.dueDate;
  final OccurrenceStatus status;
  if (occurrence.skipped) {
    status = OccurrenceStatus.skipped;
  } else if (paid >= occurrence.amount || counted.any((p) => p.settles)) {
    status = OccurrenceStatus.paid;
  } else if (paid.isPositive) {
    status = OccurrenceStatus.partiallyPaid;
  } else if (due > today) {
    status = OccurrenceStatus.upcoming;
  } else if (due == today) {
    status = OccurrenceStatus.due;
  } else if (accountDataAsOf != null && accountDataAsOf >= due) {
    status = OccurrenceStatus.unpaid;
  } else {
    status = OccurrenceStatus.unknown;
  }
  return OccurrenceState(
    occurrence: occurrence,
    status: status,
    paid: paid,
    payments: counted,
  );
}

/// Adds [payment] to [links]. A journal pays at most one occurrence, and an
/// occurrence already paid cannot be paid again, so the commitment is
/// consumed exactly once (A13).
List<OccurrencePayment> linkPayment(
  List<OccurrencePayment> links,
  OccurrencePayment payment,
  OccurrenceState current,
) {
  if (links.any((l) => l.journalId == payment.journalId)) {
    throw StateError('Journal ${payment.journalId} is already linked');
  }
  if (current.status == OccurrenceStatus.paid) {
    throw StateError('${current.occurrence.key} is already paid');
  }
  if (payment.scheduleId != current.occurrence.scheduleId ||
      payment.occurrenceDate != current.occurrence.originalDate) {
    throw ArgumentError('The payment is for a different occurrence');
  }
  return List.unmodifiable([...links, payment]);
}
