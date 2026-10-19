import 'package:meta/meta.dart';

import '../money/money.dart';
import '../time/local_date.dart';
import 'journal.dart';
import 'projection.dart';
import 'transaction_draft.dart';

class ReconciliationException implements Exception {
  ReconciliationException(this.difference);
  final Money difference;

  @override
  String toString() =>
      'Statement differs by ${difference.toDecimalString()}; confirm an adjustment or correct entries';
}

@immutable
class ReconciliationResult {
  const ReconciliationResult(
    this.accountId,
    this.statementDate,
    this.adjustment,
  );
  final String accountId;
  final LocalDate statementDate;

  /// Balance adjustment the user explicitly confirmed, if any.
  final Journal? adjustment;
}

/// A statement reconciliation session (FIN 08).
///
/// [statementBalance] is as printed on the statement: money held, or money
/// owed for a card or loan. It is an observation and never replaces the
/// calculated balance.
@immutable
class Reconciliation {
  const Reconciliation({
    required this.accountId,
    required this.statementDate,
    required this.statementBalance,
    required this.clearedJournalIds,
  });

  final String accountId;
  final LocalDate statementDate;
  final Money statementBalance;

  /// Every entry the user has ticked as on this or an earlier statement.
  final Set<String> clearedJournalIds;

  Money clearedBalance(LedgerProjection ledger) {
    final liability = ledger.chart.account(accountId).type.isLiability;
    var total = Money.zero(ledger.chart.currency);
    for (final journal in ledger.journals) {
      if (!journal.status.inPostedLedger ||
          !clearedJournalIds.contains(journal.id) ||
          journal.effectiveDate > statementDate) {
        continue;
      }
      total += journal.amountFor(accountId) ?? Money.zero(total.currency);
    }
    return liability ? -total : total;
  }

  /// Statement balance less the cleared balance; zero when reconciled.
  Money difference(LedgerProjection ledger) =>
      statementBalance - clearedBalance(ledger);

  /// Completes the session. A non-zero difference needs an explicitly
  /// confirmed balance adjustment; missing transactions are never invented.
  ReconciliationResult complete(
    LedgerProjection ledger,
    JournalFactory factory, {
    bool confirmAdjustment = false,
  }) {
    final diff = difference(ledger);
    if (diff.isZero) {
      return ReconciliationResult(accountId, statementDate, null);
    }
    if (!confirmAdjustment) throw ReconciliationException(diff);
    final adjustment = factory.build(
      TransactionDraft(
        type: TransactionType.adjustment,
        accountId: accountId,
        amount: diff,
        effectiveDate: statementDate,
        notes: 'Reconciliation adjustment',
      ),
    );
    return ReconciliationResult(accountId, statementDate, adjustment);
  }
}
