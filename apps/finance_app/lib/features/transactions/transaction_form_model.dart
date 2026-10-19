import 'package:finance_core/finance_core.dart';

import '../../widgets/amount_expression.dart';

enum EntryField { account, counterAccount, amount, category, splits, date }

/// One editable split row: a category and the amount text the user typed.
class SplitLine {
  SplitLine(this.categoryId, this.amountText);
  String? categoryId;
  String amountText;
}

/// Editable state of the transaction entry form (FIN 03 to FIN 06).
///
/// Kept free of widgets so validation and draft building are unit tested;
/// the form widget only binds controls to these fields.
class TransactionFormModel {
  TransactionFormModel(this.chart, {required LocalDate today})
    : effectiveDate = today;

  /// Prefills the form from a posted journal for an ordinary edit, which is
  /// saved as a correction (reversal plus replacement).
  factory TransactionFormModel.fromJournal(
    Chart chart,
    Journal journal, {
    required LocalDate today,
  }) {
    final form = TransactionFormModel(chart, today: today)
      ..type = journal.type
      ..accountId = journal.accountId
      ..counterAccountId = journal.counterAccountId
      ..amountText = journal.amount?.toDecimalString() ?? ''
      ..effectiveDate = journal.effectiveDate
      ..payee = journal.payee ?? ''
      ..notes = journal.notes ?? ''
      ..tags = {...journal.tags}
      ..refundOf = journal.refundOf
      ..editing = journal;
    final categoryPostings = journal.postings
        .where((p) => chart.hasCategory(p.ledgerAccountId))
        .toList();
    if (categoryPostings.length == 1) {
      form.categoryId = categoryPostings.single.ledgerAccountId;
    } else if (categoryPostings.length > 1) {
      form
        ..splitMode = true
        ..splits = [
          for (final p in categoryPostings)
            SplitLine(p.ledgerAccountId, p.amount.abs().toDecimalString()),
        ];
    }
    return form;
  }

  /// Restores fields saved by [toDraftJson] after an interruption (UX 02).
  factory TransactionFormModel.fromDraftJson(
    Chart chart,
    Map<String, Object?> json, {
    required LocalDate today,
  }) {
    String? known(Object? id) =>
        id is String && (chart.hasAccount(id) || chart.hasCategory(id))
        ? id
        : null;
    return TransactionFormModel(chart, today: today)
      ..type = TransactionType.values.byName(json['type'] as String)
      ..accountId = known(json['accountId'])
      ..counterAccountId = known(json['counterAccountId'])
      ..amountText = json['amountText'] as String? ?? ''
      ..effectiveDate = LocalDate.parse(json['effectiveDate'] as String)
      ..categoryId = known(json['categoryId'])
      ..splitMode = json['splitMode'] as bool? ?? false
      ..splits = [
        for (final s
            in (json['splits'] as List? ?? const [])
                .cast<Map<String, Object?>>())
          SplitLine(known(s['categoryId']), s['amountText'] as String? ?? ''),
      ]
      ..payee = json['payee'] as String? ?? ''
      ..notes = json['notes'] as String? ?? ''
      ..tags = {...(json['tags'] as List? ?? const []).cast<String>()}
      ..refundOf = json['refundOf'] as String?;
  }

  final Chart chart;
  TransactionType type = TransactionType.expense;
  String? accountId;
  String? counterAccountId;
  String amountText = '';
  LocalDate effectiveDate;
  String? categoryId;
  bool splitMode = false;
  List<SplitLine> splits = [];
  String payee = '';
  String notes = '';
  Set<String> tags = {};
  String? refundOf;
  JournalStatus status = JournalStatus.posted;

  /// Set when the draft comes from a receipt for a cash purchase (REC 06).
  bool requireCashConfirmation = false;
  bool cashAccountConfirmed = false;

  /// The journal being edited, if any.
  Journal? editing;

  bool get isTransfer => type == TransactionType.transfer;

  bool get needsCategory =>
      type == TransactionType.expense ||
      type == TransactionType.income ||
      type == TransactionType.refund;

  CategoryKind get _categoryKind => type == TransactionType.income
      ? CategoryKind.income
      : CategoryKind.expense;

  List<Category> get availableCategories =>
      chart.categories
          .where((c) => c.kind == _categoryKind && !c.archived)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  List<Account> get availableAccounts =>
      chart.accounts.where((a) => !a.archived).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  Money? get amount {
    try {
      return evaluateAmountExpression(amountText, chart.currency);
    } on FormatException {
      return null;
    } on MoneyRangeException {
      return null;
    }
  }

  Money? _splitAmount(SplitLine line) {
    try {
      return Money.parse(line.amountText, chart.currency);
    } on FormatException {
      return null;
    }
  }

  /// Amount still to allocate across splits; zero when they add up.
  Money? get unallocated {
    final total = amount;
    if (total == null) return null;
    var allocated = Money.zero(chart.currency);
    for (final line in splits) {
      allocated += _splitAmount(line) ?? Money.zero(chart.currency);
    }
    return total - allocated;
  }

  Map<EntryField, String> get errors {
    final errors = <EntryField, String>{};
    if (accountId == null || !chart.hasAccount(accountId!)) {
      errors[EntryField.account] = 'Choose an account';
    } else if (requireCashConfirmation &&
        chart.account(accountId!).type == AccountType.cash &&
        !cashAccountConfirmed) {
      errors[EntryField.account] =
          'Confirm this was paid from the cash account';
    }
    final total = amount;
    if (total == null) {
      errors[EntryField.amount] = 'Enter an amount such as 12.50 or 10+2.50';
    } else if (!total.isPositive) {
      errors[EntryField.amount] = 'The amount must be more than zero';
    }
    if (isTransfer) {
      if (counterAccountId == null) {
        errors[EntryField.counterAccount] = 'Choose where the money went';
      } else if (counterAccountId == accountId) {
        errors[EntryField.counterAccount] = 'Choose a different account';
      }
    } else if (needsCategory) {
      if (splitMode) {
        if (splits.isEmpty ||
            splits.any(
              (s) => s.categoryId == null || _splitAmount(s) == null,
            )) {
          errors[EntryField.splits] = 'Each split needs a category and amount';
        } else if (unallocated != null && !unallocated!.isZero) {
          final left = unallocated!;
          errors[EntryField.splits] = left.isNegative
              ? 'Splits exceed the total by ${(-left).toDecimalString()}'
              : '${left.toDecimalString()} is not yet allocated';
        }
      } else if (categoryId == null) {
        errors[EntryField.category] = 'Choose a category';
      }
    }
    return errors;
  }

  bool get hasInput =>
      amountText.trim().isNotEmpty ||
      payee.trim().isNotEmpty ||
      notes.trim().isNotEmpty;

  Map<String, Object?> toDraftJson() => {
    'type': type.name,
    'accountId': accountId,
    'counterAccountId': counterAccountId,
    'amountText': amountText,
    'effectiveDate': effectiveDate.toString(),
    'categoryId': categoryId,
    'splitMode': splitMode,
    'splits': [
      for (final s in splits)
        {'categoryId': s.categoryId, 'amountText': s.amountText},
    ],
    'payee': payee,
    'notes': notes,
    'tags': tags.toList()..sort(),
    'refundOf': refundOf,
  };

  /// Builds the draft; call only when [errors] is empty.
  TransactionDraft toDraft() {
    if (errors.isNotEmpty) {
      throw StateError('Form has errors: ${errors.values.join('; ')}');
    }
    final total = amount!;
    final lines = !needsCategory
        ? const <Split>[]
        : splitMode
        ? [for (final s in splits) Split(s.categoryId!, _splitAmount(s)!)]
        : [Split(categoryId!, total)];
    return TransactionDraft(
      type: type,
      accountId: accountId!,
      counterAccountId: isTransfer ? counterAccountId : null,
      amount: total,
      effectiveDate: effectiveDate,
      splits: lines,
      status: status,
      payee: payee.trim().isEmpty ? null : payee.trim(),
      notes: notes.trim().isEmpty ? null : notes.trim(),
      tags: tags,
      refundOf: type == TransactionType.refund ? refundOf : null,
    );
  }
}
