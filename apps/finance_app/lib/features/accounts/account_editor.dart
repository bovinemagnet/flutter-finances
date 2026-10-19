import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

const accountTypeLabels = {
  AccountType.transaction: 'Everyday account',
  AccountType.savings: 'Savings',
  AccountType.cash: 'Cash',
  AccountType.creditCard: 'Credit card',
  AccountType.loan: 'Loan',
  AccountType.property: 'Property',
  AccountType.investment: 'Investments',
  AccountType.superannuation: 'Superannuation',
  AccountType.otherAsset: 'Other asset',
};

/// Result of the account editor: the account plus an optional opening
/// balance, which adjusts opening equity and is never income (FIN 01).
class AccountEdit {
  AccountEdit(this.account, this.openingBalance, this.openingBalanceDate);
  final Account account;
  final Money? openingBalance;
  final LocalDate openingBalanceDate;

  TransactionDraft? openingBalanceDraft() =>
      openingBalance == null || openingBalance!.isZero
      ? null
      : TransactionDraft(
          type: TransactionType.openingBalance,
          accountId: account.id,
          amount: openingBalance!,
          effectiveDate: openingBalanceDate,
          notes: 'Opening balance',
        );
}

class AccountEditor extends StatefulWidget {
  const AccountEditor({
    super.key,
    required this.currency,
    required this.today,
    required this.onSave,
    this.existing,
  });

  final Currency currency;
  final LocalDate today;
  final Account? existing;
  final Future<void> Function(AccountEdit edit) onSave;

  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final _formKey = GlobalKey<FormState>();
  late String _name = widget.existing?.name ?? '';
  late AccountType _type = widget.existing?.type ?? AccountType.transaction;
  late bool _budget = widget.existing?.includeInBudget ?? true;
  late bool _forecast = widget.existing?.includeInForecast ?? true;
  late bool _netWorth = widget.existing?.includeInNetWorth ?? true;
  late bool _archived = widget.existing?.archived ?? false;
  late bool _shared = widget.existing?.sharing == AccountSharing.shared;
  String _opening = '';
  late LocalDate _openingDate = widget.today;

  bool get _isNew => widget.existing == null;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final opening = _opening.trim().isEmpty
        ? null
        : Money.parse(_opening, widget.currency);
    final account = Account(
      id: widget.existing?.id ?? newId(),
      name: _name.trim(),
      type: _type,
      includeInBudget: _budget,
      includeInForecast: _forecast,
      includeInNetWorth: _netWorth,
      archived: _archived,
      dataSource: widget.existing?.dataSource ?? 'manual',
      lastReconciledOn: widget.existing?.lastReconciledOn,
      sharing: _shared ? AccountSharing.shared : AccountSharing.private,
    );
    await widget.onSave(AccountEdit(account, opening, _openingDate));
  }

  @override
  Widget build(BuildContext context) {
    final liability = _type.isLiability;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            initialValue: _name,
            decoration: const InputDecoration(labelText: 'Account name'),
            textCapitalization: TextCapitalization.words,
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Give the account a name' : null,
            onChanged: (v) => _name = v,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<AccountType>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final entry in accountTypeLabels.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _isNew ? (t) => setState(() => _type = t!) : null,
          ),
          if (_isNew) ...[
            const SizedBox(height: 16),
            TextFormField(
              decoration: InputDecoration(
                labelText: liability ? 'Amount owed' : 'Opening balance',
                prefixText: r'$ ',
                helperText: 'Not counted as income',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) return null;
                try {
                  Money.parse(v!, widget.currency);
                  return null;
                } on FormatException {
                  return 'Enter an amount such as 1250.00';
                }
              },
              onChanged: (v) => _opening = v,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Balance as at'),
              subtitle: Text(formatDate(_openingDate)),
              trailing: TextButton(
                child: const Text('Change'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime(
                      _openingDate.year,
                      _openingDate.month,
                      _openingDate.day,
                    ),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    setState(
                      () => _openingDate = LocalDate.fromDateTime(picked),
                    );
                  }
                },
              ),
            ),
          ],
          const Divider(),
          SwitchListTile(
            value: !_budget,
            title: const Text('Leave out of budgets'),
            onChanged: (v) => setState(() => _budget = !v),
          ),
          SwitchListTile(
            value: !_forecast,
            title: const Text('Leave out of the cash forecast'),
            onChanged: (v) => setState(() => _forecast = !v),
          ),
          SwitchListTile(
            value: !_netWorth,
            title: const Text('Leave out of net worth'),
            onChanged: (v) => setState(() => _netWorth = !v),
          ),
          SwitchListTile(
            value: _shared,
            title: const Text('Share with my household'),
            subtitle: const Text(
              'Members of a shared workspace see this account and its '
              'transactions; otherwise only you do',
            ),
            onChanged: (v) => setState(() => _shared = v),
          ),
          if (!_isNew)
            SwitchListTile(
              value: _archived,
              title: const Text('Archive (keeps history)'),
              onChanged: (v) => setState(() => _archived = v),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _save,
              child: const Text('Save account'),
            ),
          ),
        ],
      ),
    );
  }
}
