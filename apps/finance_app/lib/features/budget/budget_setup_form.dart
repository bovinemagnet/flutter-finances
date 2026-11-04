import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/breakpoints.dart';
import '../../format/formatters.dart';
import '../onboarding/onboarding_model.dart';

const payFrequencies = {
  Frequency.weekly: 'Weekly',
  Frequency.fortnightly: 'Fortnightly',
  Frequency.monthly: 'Monthly',
};

/// The choices behind a budget: take-home pay, a pay cycle and a template.
/// Used during first-run setup and when a budget is set up later.
class BudgetSetupForm extends StatefulWidget {
  const BudgetSetupForm({
    super.key,
    required this.model,
    required this.payAccounts,
    required this.onChanged,
  });

  final OnboardingModel model;

  /// Accounts that pay can go into.
  final List<Account> payAccounts;

  /// Called after the choices in [model] change.
  final VoidCallback onChanged;

  @override
  State<BudgetSetupForm> createState() => _BudgetSetupFormState();
}

class _BudgetSetupFormState extends State<BudgetSetupForm> {
  OnboardingModel get model => widget.model;
  String? _payError;

  void _change(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final compact =
        windowClassFor(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          decoration: InputDecoration(
            labelText: 'Take-home pay',
            prefixText: r'$ ',
            errorText: _payError,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          initialValue: model.takeHomePay?.toDecimalString(),
          onChanged: (text) => _change(() {
            if (text.trim().isEmpty) {
              model.takeHomePay = null;
              _payError = null;
              return;
            }
            try {
              model.takeHomePay = Money.parse(text, model.currency);
              _payError = null;
            } on FormatException {
              _payError = 'Enter an amount such as 3123.45';
            }
          }),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<Frequency>(
          initialValue: model.payFrequency,
          decoration: const InputDecoration(labelText: 'Paid'),
          items: [
            for (final e in payFrequencies.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (f) => _change(() => model.payFrequency = f!),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Next payday'),
          subtitle: Text(formatDate(model.nextPayday ?? model.today)),
          trailing: TextButton(
            child: const Text('Change'),
            onPressed: () async {
              final start = model.nextPayday ?? model.today;
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime(start.year, start.month, start.day),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                _change(
                  () => model.nextPayday = LocalDate.fromDateTime(picked),
                );
              }
            },
          ),
        ),
        if (widget.payAccounts.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: model.payAccountId,
            decoration: const InputDecoration(labelText: 'Pay goes into'),
            items: [
              for (final account in widget.payAccounts)
                DropdownMenuItem(value: account.id, child: Text(account.name)),
            ],
            onChanged: (id) => _change(() => model.payAccountId = id),
          ),
        const SizedBox(height: 8),
        // Three long labels only keep their words whole on a phone without
        // the selected icon.
        SegmentedButton<BudgetMode>(
          showSelectedIcon: !compact,
          style: compact
              ? const ButtonStyle(
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 4),
                  ),
                )
              : null,
          segments: const [
            ButtonSegment(
              value: BudgetMode.groups,
              label: Text('Needs, wants, savings'),
            ),
            ButtonSegment(
              value: BudgetMode.zeroBased,
              label: Text('Every dollar assigned'),
            ),
            ButtonSegment(
              value: BudgetMode.categoryOnly,
              label: Text('Categories only'),
            ),
          ],
          selected: {model.budgetMode},
          onSelectionChanged: (s) =>
              _change(() => model.budgetMode = s.single),
        ),
        if (model.budgetMode == BudgetMode.groups) ...[
          for (final group in defaultGroups)
            Row(
              children: [
                SizedBox(width: 120, child: Text(group.name)),
                Expanded(
                  child: Slider(
                    value: (model.shares[group.id]! / 100).toDouble(),
                    max: 100,
                    divisions: 20,
                    label: '${model.shares[group.id]! ~/ 100}%',
                    semanticFormatterCallback: (v) =>
                        '${group.name} ${v.round()} percent',
                    onChanged: (v) => _change(
                      () => model.shares[group.id] = v.round() * 100,
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text('${model.shares[group.id]! ~/ 100}%'),
                ),
              ],
            ),
          if (model.shareError != null)
            Text(
              model.shareError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ],
    );
  }
}
