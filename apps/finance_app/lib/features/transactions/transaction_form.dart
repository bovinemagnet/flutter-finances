import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';
import '../../widgets/amount_field.dart';
import 'transaction_form_model.dart';

/// Entry form for expenses, income, transfers and refunds.
///
/// Uses everyday words only; the ledger mapping happens in `JournalFactory`.
class TransactionForm extends StatefulWidget {
  const TransactionForm({
    super.key,
    required this.model,
    required this.onSave,
    this.onCancel,
  });

  final TransactionFormModel model;
  final Future<void> Function(TransactionDraft draft) onSave;
  final VoidCallback? onCancel;

  @override
  State<TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends State<TransactionForm> {
  TransactionFormModel get model => widget.model;
  var _showErrors = false;
  var _saving = false;
  late final _tagController = TextEditingController();

  static const _types = [
    (TransactionType.expense, 'Expense', Icons.remove_circle_outline),
    (TransactionType.income, 'Income', Icons.add_circle_outline),
    (TransactionType.transfer, 'Transfer', Icons.swap_horiz),
    (TransactionType.refund, 'Refund', Icons.undo),
  ];

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _showErrors = true);
    if (model.errors.isNotEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(model.toDraft());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final current = model.effectiveDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Date the money moved',
    );
    if (picked != null) {
      setState(() => model.effectiveDate = LocalDate.fromDateTime(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final errors = _showErrors ? model.errors : const <EntryField, String>{};
    final accounts = model.availableAccounts;
    final categories = model.availableCategories;
    final editingTypeLocked = model.editing != null;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<TransactionType>(
              segments: [
                for (final (type, label, icon) in _types)
                  ButtonSegment(
                    value: type,
                    label: Text(label),
                    icon: Icon(icon),
                  ),
              ],
              selected: {model.type},
              onSelectionChanged: editingTypeLocked
                  ? null
                  : (selection) => setState(() {
                      model.type = selection.single;
                      model.categoryId = null;
                      model.splits = [];
                      model.splitMode = false;
                    }),
            ),
            const SizedBox(height: 16),
            AmountField(
              currency: model.chart.currency,
              initialText: model.amountText,
              autofocus: model.editing == null,
              errorText: errors[EntryField.amount],
              onChanged: (text) => setState(() => model.amountText = text),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: model.accountId,
              decoration: InputDecoration(
                labelText: model.isTransfer ? 'From account' : 'Account',
                errorText: errors[EntryField.account],
              ),
              items: [
                for (final a in accounts)
                  DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (id) => setState(() {
                model.accountId = id;
                model.cashAccountConfirmed = false;
              }),
            ),
            if (model.requireCashConfirmation &&
                model.accountId != null &&
                model.chart.account(model.accountId!).type == AccountType.cash)
              CheckboxListTile(
                value: model.cashAccountConfirmed,
                title: const Text('Paid in cash from this account'),
                onChanged: (v) =>
                    setState(() => model.cashAccountConfirmed = v ?? false),
              ),
            if (model.isTransfer) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: model.counterAccountId,
                decoration: InputDecoration(
                  labelText: 'To account',
                  helperText:
                      'Paying a card or loan is a transfer, not spending',
                  errorText: errors[EntryField.counterAccount],
                ),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (id) => setState(() => model.counterAccountId = id),
              ),
            ],
            if (model.needsCategory) ...[
              const SizedBox(height: 16),
              if (!model.splitMode)
                DropdownButtonFormField<String>(
                  initialValue: model.categoryId,
                  decoration: InputDecoration(
                    labelText: 'Category',
                    errorText: errors[EntryField.category],
                  ),
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (id) => setState(() => model.categoryId = id),
                )
              else
                _SplitEditor(
                  model: model,
                  categories: categories,
                  errorText: errors[EntryField.splits],
                  onChanged: () => setState(() {}),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: Icon(
                    model.splitMode ? Icons.call_merge : Icons.call_split,
                  ),
                  label: Text(
                    model.splitMode
                        ? 'Use one category'
                        : 'Split across categories',
                  ),
                  onPressed: () => setState(() {
                    model.splitMode = !model.splitMode;
                    if (model.splitMode && model.splits.isEmpty) {
                      model.splits = [
                        SplitLine(model.categoryId, model.amountText),
                        SplitLine(null, ''),
                      ];
                    }
                  }),
                ),
              ),
            ],
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('Date'),
              subtitle: Text(formatDate(model.effectiveDate)),
              trailing: TextButton(
                onPressed: _pickDate,
                child: const Text('Change'),
              ),
            ),
            TextFormField(
              initialValue: model.payee,
              decoration: InputDecoration(
                labelText: model.type == TransactionType.income
                    ? 'Payer'
                    : 'Merchant or payee',
              ),
              textCapitalization: TextCapitalization.words,
              onChanged: (v) => model.payee = v,
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: model.notes,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 2,
              onChanged: (v) => model.notes = v,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final tag in model.tags)
                  InputChip(
                    label: Text(tag),
                    onDeleted: () => setState(() => model.tags.remove(tag)),
                    deleteButtonTooltipMessage: 'Remove tag $tag',
                  ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _tagController,
                    decoration: const InputDecoration(
                      labelText: 'Add tag',
                      hintText: 'holiday, reimbursable',
                    ),
                    onSubmitted: (v) => setState(() {
                      final tag = v.trim().toLowerCase();
                      if (tag.isNotEmpty) model.tags.add(tag);
                      _tagController.clear();
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(model.editing == null ? 'Save' : 'Save changes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitEditor extends StatelessWidget {
  const _SplitEditor({
    required this.model,
    required this.categories,
    required this.errorText,
    required this.onChanged,
  });

  final TransactionFormModel model;
  final List<Category> categories;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final left = model.unallocated;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Splits',
        errorText: errorText,
        helperText: left == null
            ? null
            : left.isZero
            ? 'Fully allocated'
            : '${formatMoney(left)} left to allocate',
      ),
      child: Column(
        children: [
          for (final (index, line) in model.splits.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      initialValue: line.categoryId,
                      decoration: InputDecoration(
                        labelText: 'Category ${index + 1}',
                      ),
                      items: [
                        for (final c in categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (id) {
                        line.categoryId = id;
                        onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      initialValue: line.amountText,
                      decoration: InputDecoration(
                        labelText: 'Amount ${index + 1}',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (v) {
                        line.amountText = v;
                        onChanged();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove split ${index + 1}',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () {
                      model.splits.removeAt(index);
                      onChanged();
                    },
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add split'),
              onPressed: () {
                model.splits.add(
                  SplitLine(
                    null,
                    left?.isPositive == true ? left!.toDecimalString() : '',
                  ),
                );
                onChanged();
              },
            ),
          ),
        ],
      ),
    );
  }
}
