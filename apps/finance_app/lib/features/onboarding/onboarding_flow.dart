import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart' show SyncMode;
import 'package:flutter/material.dart';

import '../../format/formatters.dart';
import '../accounts/account_editor.dart';
import '../budget/budget_setup_form.dart';
import 'onboarding_model.dart';

const australianTimezones = [
  'Australia/Brisbane',
  'Australia/Sydney',
  'Australia/Melbourne',
  'Australia/Hobart',
  'Australia/Adelaide',
  'Australia/Darwin',
  'Australia/Perth',
];

/// First-run setup (Journey A). Nothing here needs an online account.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.model,
    required this.onFinish,
    this.headerActions,
  });

  final OnboardingModel model;
  final Future<void> Function(OnboardingResult result) onFinish;

  /// Other ways to start, shown above the steps.
  final Widget? headerActions;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  OnboardingModel get model => widget.model;
  var _step = 0;
  var _finishing = false;

  static const _stepCount = 5;

  bool get _canContinue => switch (_step) {
    3 =>
      model.budgetMode == BudgetMode.categoryOnly || model.shareError == null,
    _ => true,
  };

  Future<void> _next() async {
    if (!_canContinue) return;
    if (_step < _stepCount - 1) {
      setState(() => _step++);
      return;
    }
    setState(() => _finishing = true);
    try {
      await widget.onFinish(model.build());
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Future<void> _addAccount() async {
    final edit = await Navigator.of(context).push<AccountEdit>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Add account')),
          body: AccountEditor(
            currency: model.currency,
            today: model.today,
            onSave: (edit) async => Navigator.of(context).pop(edit),
          ),
        ),
      ),
    );
    if (edit != null) setState(() => model.accounts.add(edit));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your finances')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.headerActions != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: widget.headerActions,
            ),
          Expanded(child: _steps()),
        ],
      ),
    );
  }

  Widget _steps() {
    // Step numbers grow with the text, so their circles must grow too.
    final circle = MediaQuery.textScalerOf(context).scale(24).clamp(24.0, 80.0);
    return Stepper(
      stepIconWidth: circle,
      stepIconHeight: circle,
      currentStep: _step,
      onStepTapped: (i) => setState(() => _step = i),
      onStepContinue: _finishing ? null : _next,
      onStepCancel: _step == 0 ? null : () => setState(() => _step--),
      controlsBuilder: (context, details) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          children: [
            FilledButton(
              onPressed: _canContinue ? details.onStepContinue : null,
              child: Text(_step == _stepCount - 1 ? 'Finish' : 'Continue'),
            ),
            const SizedBox(width: 8),
            if (details.onStepCancel != null)
              TextButton(
                onPressed: details.onStepCancel,
                child: const Text('Back'),
              ),
          ],
        ),
      ),
      steps: [
        Step(
          title: const Text('Region'),
          content: _region(),
          isActive: _step >= 0,
        ),
        Step(
          title: const Text('Where your data lives'),
          content: _storage(),
          isActive: _step >= 1,
        ),
        Step(
          title: const Text('Accounts'),
          content: _accounts(),
          isActive: _step >= 2,
        ),
        Step(
          title: const Text('Budget'),
          content: _budget(),
          isActive: _step >= 3,
        ),
        Step(
          title: const Text('Review'),
          content: _review(),
          isActive: _step >= 4,
        ),
      ],
    );
  }

  Widget _region() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Currency'),
        subtitle: Text('Australian dollar (AUD). One currency per workspace.'),
      ),
      DropdownButtonFormField<String>(
        initialValue: model.timezone,
        decoration: const InputDecoration(labelText: 'Time zone'),
        items: [
          for (final zone in australianTimezones)
            DropdownMenuItem(value: zone, child: Text(zone.split('/').last)),
        ],
        onChanged: (zone) => setState(() => model.timezone = zone!),
      ),
      const SizedBox(height: 8),
      const Text(
        'Dates are shown as day/month/year and the financial year '
        'runs July to June.',
      ),
    ],
  );

  Widget _storage() => RadioGroup<SyncMode>(
    groupValue: model.syncMode,
    onChanged: (mode) => setState(() => model.syncMode = mode!),
    child: const Column(
      children: [
        RadioListTile<SyncMode>(
          value: SyncMode.local,
          title: Text('Only on this device'),
          subtitle: Text(
            'No account needed. Your data can only be recovered '
            'from a backup you create, so the app will remind you to make one.',
          ),
        ),
        RadioListTile<SyncMode>(
          value: SyncMode.synced,
          title: Text('Sync between my devices'),
          subtitle: Text(
            'Sign in later to keep devices up to date. You can '
            'start on this device now and turn sync on at any time.',
          ),
        ),
      ],
    ),
  );

  Widget _accounts() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Add the bank, cash and card accounts you want to track. '
        'Opening balances are not counted as income.',
      ),
      for (final edit in model.accounts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.account_balance_outlined),
          title: Text(edit.account.name),
          subtitle: Text(
            [
              accountTypeLabels[edit.account.type]!,
              if (edit.openingBalance != null)
                '${edit.account.type.isLiability ? 'owed' : 'balance'} '
                    '${formatMoney(edit.openingBalance!)} on ${formatDate(edit.openingBalanceDate)}',
            ].join(' · '),
          ),
          trailing: IconButton(
            tooltip: 'Remove ${edit.account.name}',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => model.accounts.remove(edit)),
          ),
        ),
      TextButton.icon(
        onPressed: _addAccount,
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
    ],
  );

  Widget _budget() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Use your take-home pay. The app does not estimate tax or '
        'superannuation. You can skip this and set a budget later.',
      ),
      const SizedBox(height: 8),
      BudgetSetupForm(
        model: model,
        payAccounts: [
          for (final e in model.accounts)
            if (!e.account.type.isLiability) e.account,
        ],
        onChanged: () => setState(() {}),
      ),
    ],
  );

  Widget _review() {
    final pay = model.takeHomePay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${model.accounts.length} '
          '${model.accounts.length == 1 ? 'account' : 'accounts'}',
        ),
        Text(
          pay == null
              ? 'No budget yet'
              : '${payFrequencies[model.payFrequency]} budget from ${formatMoney(pay)} take-home pay',
        ),
        Text(
          model.syncMode == SyncMode.local
              ? 'Stored only on this device'
              : 'Sync can be turned on after signing in',
        ),
        const SizedBox(height: 8),
        const Text('You can import a bank statement (CSV) after setup.'),
      ],
    );
  }
}
