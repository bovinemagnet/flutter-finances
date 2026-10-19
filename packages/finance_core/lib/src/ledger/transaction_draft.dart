import 'package:meta/meta.dart';

import '../ids.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'accounts.dart';
import 'journal.dart';

@immutable
class Split {
  const Split(this.categoryId, this.amount);
  final String categoryId;
  final Money amount;
}

/// A user's entry before it becomes a balanced journal (FIN 03).
///
/// [amount] is always a positive magnitude, except for [TransactionType
/// .adjustment] and [TransactionType.openingBalance], where it is the signed
/// change or balance from the user's point of view (money held for assets,
/// money owed for liabilities).
@immutable
class TransactionDraft {
  const TransactionDraft({
    required this.type,
    required this.accountId,
    required this.amount,
    required this.effectiveDate,
    this.counterAccountId,
    this.splits = const [],
    this.status = JournalStatus.posted,
    this.payee,
    this.notes,
    this.tags = const {},
    this.refundOf,
    this.id,
    this.enteredAt,
  });

  final TransactionType type;
  final String accountId;
  final Money amount;
  final LocalDate effectiveDate;
  final String? counterAccountId;
  final List<Split> splits;
  final JournalStatus status;
  final String? payee;
  final String? notes;
  final Set<String> tags;
  final String? refundOf;
  final String? id;
  final DateTime? enteredAt;
}

enum DraftError {
  unknownAccount('UNKNOWN_ACCOUNT'),
  unknownCategory('UNKNOWN_CATEGORY'),
  wrongCategoryKind('WRONG_CATEGORY_KIND'),
  splitMismatch('SPLIT_MISMATCH'),
  missingSplits('MISSING_SPLITS'),
  nonPositiveAmount('NON_POSITIVE_AMOUNT'),
  sameAccount('SAME_ACCOUNT'),
  currencyMismatch('CURRENCY_MISMATCH'),
  invalidStatus('INVALID_STATUS');

  const DraftError(this.code);
  final String code;
}

class DraftException implements Exception {
  DraftException(this.code, [this.detail]);
  final DraftError code;
  final String? detail;

  @override
  String toString() =>
      'DraftException(${code.code}${detail == null ? '' : ': $detail'})';
}

/// Turns user entries into balanced journals without exposing accounting
/// terminology to the interface.
class JournalFactory {
  JournalFactory(this.chart);

  final Chart chart;

  Journal build(TransactionDraft draft) {
    _require(
      chart.hasAccount(draft.accountId),
      DraftError.unknownAccount,
      draft.accountId,
    );
    _require(
      draft.amount.currency == chart.currency,
      DraftError.currencyMismatch,
    );
    _require(draft.status != JournalStatus.reversed, DraftError.invalidStatus);
    final account = draft.accountId;
    final postings = switch (draft.type) {
      TransactionType.expense => _categorised(
        draft,
        CategoryKind.expense,
        (amount) => [Posting(account, -amount)],
        sign: 1,
      ),
      TransactionType.income => _categorised(
        draft,
        CategoryKind.income,
        (amount) => [Posting(account, amount)],
        sign: -1,
      ),
      TransactionType.refund => _categorised(
        draft,
        CategoryKind.expense,
        (amount) => [Posting(account, amount)],
        sign: -1,
      ),
      TransactionType.transfer => _transfer(draft),
      TransactionType.openingBalance => _againstSystem(
        draft,
        SystemAccounts.openingEquity,
      ),
      TransactionType.adjustment => _againstSystem(
        draft,
        SystemAccounts.balanceAdjustments,
      ),
      TransactionType.reimbursableExpense => _positive(
        draft,
        () => [
          Posting(SystemAccounts.reimbursementReceivable, draft.amount),
          Posting(account, -draft.amount),
        ],
      ),
      TransactionType.reimbursement =>
        draft.splits.isEmpty
            ? _positive(
                draft,
                () => [
                  Posting(account, draft.amount),
                  Posting(
                    SystemAccounts.reimbursementReceivable,
                    -draft.amount,
                  ),
                ],
              )
            : _categorised(
                draft,
                CategoryKind.expense,
                (amount) => [Posting(account, amount)],
                sign: -1,
              ),
      TransactionType.reversal => throw ArgumentError(
        'Use correctJournal to create reversals',
      ),
    };
    return Journal(
      id: draft.id ?? newId(),
      type: draft.type,
      status: draft.status,
      effectiveDate: draft.effectiveDate,
      enteredAt: draft.enteredAt ?? DateTime.now().toUtc(),
      postings: postings,
      accountId: draft.accountId,
      counterAccountId: draft.counterAccountId,
      amount: draft.amount,
      payee: draft.payee,
      notes: draft.notes,
      tags: draft.tags,
      refundOf: draft.refundOf,
    );
  }

  List<Posting> _categorised(
    TransactionDraft draft,
    CategoryKind kind,
    List<Posting> Function(Money amount) accountSide, {
    required int sign,
  }) {
    return _positive(draft, () {
      _require(draft.splits.isNotEmpty, DraftError.missingSplits);
      var total = Money.zero(chart.currency);
      final postings = <Posting>[];
      for (final split in draft.splits) {
        _require(
          chart.hasCategory(split.categoryId),
          DraftError.unknownCategory,
          split.categoryId,
        );
        _require(
          chart.category(split.categoryId).kind == kind,
          DraftError.wrongCategoryKind,
          split.categoryId,
        );
        _require(split.amount.isPositive, DraftError.nonPositiveAmount);
        total += split.amount;
        postings.add(
          Posting(split.categoryId, sign > 0 ? split.amount : -split.amount),
        );
      }
      _require(
        total == draft.amount,
        DraftError.splitMismatch,
        '${total.toDecimalString()} != ${draft.amount.toDecimalString()}',
      );
      return [...postings, ...accountSide(draft.amount)];
    });
  }

  List<Posting> _transfer(TransactionDraft draft) {
    final to = draft.counterAccountId;
    _require(to != null && chart.hasAccount(to), DraftError.unknownAccount, to);
    _require(to != draft.accountId, DraftError.sameAccount);
    return _positive(
      draft,
      () => [
        Posting(to!, draft.amount),
        Posting(draft.accountId, -draft.amount),
      ],
    );
  }

  List<Posting> _againstSystem(TransactionDraft draft, String systemAccount) {
    _require(!draft.amount.isZero, DraftError.nonPositiveAmount);
    final kind = chart.account(draft.accountId).type.ledgerKind;
    final delta = toLedgerSign(kind, draft.amount);
    return [Posting(draft.accountId, delta), Posting(systemAccount, -delta)];
  }

  List<Posting> _positive(
    TransactionDraft draft,
    List<Posting> Function() build,
  ) {
    _require(draft.amount.isPositive, DraftError.nonPositiveAmount);
    return build();
  }

  void _require(bool condition, DraftError code, [String? detail]) {
    if (!condition) throw DraftException(code, detail);
  }
}
