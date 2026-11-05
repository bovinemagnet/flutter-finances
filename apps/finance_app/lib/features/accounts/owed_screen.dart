import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/page_insets.dart';
import '../../format/formatters.dart';

/// What other people owe, with a way to record money coming back. Nothing here
/// happens by itself: each repayment is entered and confirmed by the person.
class OwedScreen extends StatelessWidget {
  const OwedScreen({super.key});

  Future<void> _recordRepayment(BuildContext context, OwedItem item) async {
    final state = AppScope.of(context);
    final result = await showDialog<_Repayment>(
      context: context,
      builder: (_) => _RepaymentDialog(item: item),
    );
    if (result == null) return;
    await state.recordRepayment(
      item,
      amount: result.amount,
      accountId: result.accountId,
      date: state.today(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final owed = AppScope.of(context).owed;
    return Scaffold(
      appBar: AppBar(title: const Text('Owed to you')),
      body: owed.items.isEmpty && !owed.unmatched.isPositive
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nobody owes you anything right now. When you pay for someone '
                  'else, turn on "Someone will pay me back" on the expense.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.only(bottom: listEndPadding(context)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${formatMoney(owed.total)} owed to you',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                for (final item in owed.items)
                  ListTile(
                    title: Text(
                      item.journal.payee ??
                          item.journal.notes ??
                          'Paid for someone',
                    ),
                    subtitle: Text(
                      [
                        formatDate(item.journal.effectiveDate),
                        if (item.repaid.isPositive)
                          '${formatMoney(item.repaid)} repaid',
                      ].join(' · '),
                    ),
                    trailing: Text(formatMoney(item.outstanding)),
                    onTap: () => _recordRepayment(context, item),
                  ),
                if (owed.unmatched.isPositive)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${formatMoney(owed.unmatched)} received that is not '
                      'matched to anything above, so the total is lower.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Repayment {
  const _Repayment(this.amount, this.accountId);
  final Money amount;
  final String accountId;
}

class _RepaymentDialog extends StatefulWidget {
  const _RepaymentDialog({required this.item});
  final OwedItem item;

  @override
  State<_RepaymentDialog> createState() => _RepaymentDialogState();
}

class _RepaymentDialogState extends State<_RepaymentDialog> {
  late final _amount = TextEditingController(
    text: widget.item.outstanding.toDecimalString(),
  );
  late String _accountId = widget.item.journal.accountId!;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Money? get _parsed {
    try {
      return Money.parse(_amount.text.trim(), widget.item.outstanding.currency);
    } on FormatException {
      return null;
    }
  }

  String? get _error {
    final amount = _parsed;
    if (amount == null || !amount.isPositive) {
      return 'Enter an amount such as 12.50';
    }
    if (amount > widget.item.outstanding) {
      return 'That is more than is owed '
          '(${formatMoney(widget.item.outstanding)})';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final accounts =
        AppScope.of(context).chart.accounts.where((a) => !a.archived).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final error = _error;
    return AlertDialog(
      title: const Text('Record a repayment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Amount received',
              prefixText: r'$ ',
              errorText: error,
              errorMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Paid into'),
            items: [
              for (final account in accounts)
                DropdownMenuItem(value: account.id, child: Text(account.name)),
            ],
            onChanged: (id) => setState(() => _accountId = id ?? _accountId),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: error != null
              ? null
              : () =>
                    Navigator.of(context).pop(_Repayment(_parsed!, _accountId)),
          child: const Text('Record repayment'),
        ),
      ],
    );
  }
}
