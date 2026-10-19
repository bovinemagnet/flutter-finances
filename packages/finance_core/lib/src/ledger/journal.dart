import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';

/// Lifecycle of a journal (FIN 07).
///
/// `posted` and `reversed` journals form the posted ledger: a reversed
/// journal still counts, and its linked reversal journal cancels it, so past
/// periods remain reproducible. `pending` journals only affect the pending
/// view and `draft` journals affect nothing.
enum JournalStatus {
  draft,
  pending,
  posted,
  reversed;

  bool get inPostedLedger => this == posted || this == reversed;
}

/// What the user entered; drives presentation, not arithmetic.
enum TransactionType {
  expense,
  income,
  transfer,
  refund,
  adjustment,
  openingBalance,
  reimbursableExpense,
  reimbursement,
  reversal,
}

/// One line of a journal. Debits are positive, credits negative.
@immutable
class Posting {
  const Posting(this.ledgerAccountId, this.amount);

  final String ledgerAccountId;
  final Money amount;

  Posting negated() => Posting(ledgerAccountId, -amount);

  @override
  bool operator ==(Object other) =>
      other is Posting &&
      other.ledgerAccountId == ledgerAccountId &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(ledgerAccountId, amount);

  @override
  String toString() => '$ledgerAccountId ${amount.toDecimalString()}';
}

@immutable
class Journal {
  Journal({
    required this.id,
    required this.type,
    required this.status,
    required this.effectiveDate,
    required this.enteredAt,
    required List<Posting> postings,
    this.accountId,
    this.counterAccountId,
    this.amount,
    this.payee,
    this.notes,
    Set<String> tags = const {},
    this.refundOf,
    this.reversalOf,
    this.replaces,
  }) : postings = List.unmodifiable(postings),
       tags = Set.unmodifiable(tags);

  final String id;
  final TransactionType type;
  final JournalStatus status;
  final LocalDate effectiveDate;

  /// When the entry was recorded (UTC), distinct from [effectiveDate].
  final DateTime enteredAt;
  final List<Posting> postings;

  /// The user account the entry was made against, for listing.
  final String? accountId;
  final String? counterAccountId;

  /// The user-facing magnitude of the entry.
  final Money? amount;
  final String? payee;
  final String? notes;
  final Set<String> tags;
  final String? refundOf;
  final String? reversalOf;
  final String? replaces;

  Journal copyWith({
    JournalStatus? status,
    String? payee,
    String? notes,
    Set<String>? tags,
  }) => Journal(
    id: id,
    type: type,
    status: status ?? this.status,
    effectiveDate: effectiveDate,
    enteredAt: enteredAt,
    postings: postings,
    accountId: accountId,
    counterAccountId: counterAccountId,
    amount: amount,
    payee: payee ?? this.payee,
    notes: notes ?? this.notes,
    tags: tags ?? this.tags,
    refundOf: refundOf,
    reversalOf: reversalOf,
    replaces: replaces,
  );

  /// Sum of postings against one ledger account.
  Money? amountFor(String ledgerAccountId) {
    Money? total;
    for (final posting in postings) {
      if (posting.ledgerAccountId == ledgerAccountId) {
        total = total == null ? posting.amount : total + posting.amount;
      }
    }
    return total;
  }
}

/// Stable codes shared with the server's validation (spec fixtures).
enum LedgerError {
  empty('EMPTY'),
  tooFewPostings('TOO_FEW_POSTINGS'),
  unbalanced('UNBALANCED'),
  mixedCurrency('MIXED_CURRENCY'),
  zeroAmount('ZERO_AMOUNT'),
  outOfRange('OUT_OF_RANGE');

  const LedgerError(this.code);
  final String code;
}

/// Checks that postings form a valid balanced journal in one currency.
///
/// The journal is out of range when its total debits exceed
/// [maxMinorMagnitude], which keeps the check independent of posting order.
List<LedgerError> validatePostings(List<Posting> postings) {
  if (postings.isEmpty) return [LedgerError.empty];
  final errors = <LedgerError>[];
  if (postings.length < 2) errors.add(LedgerError.tooFewPostings);
  final currency = postings.first.amount.currency;
  if (postings.any((p) => p.amount.currency != currency)) {
    return [...errors, LedgerError.mixedCurrency];
  }
  var net = 0;
  var debits = 0;
  for (final posting in postings) {
    net += posting.amount.minor;
    if (posting.amount.minor > 0) debits += posting.amount.minor;
  }
  if (net != 0) errors.add(LedgerError.unbalanced);
  if (postings.any((p) => p.amount.isZero)) errors.add(LedgerError.zeroAmount);
  if (debits > maxMinorMagnitude) errors.add(LedgerError.outOfRange);
  return errors;
}
