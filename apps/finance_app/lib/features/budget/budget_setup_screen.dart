import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../onboarding/onboarding_model.dart';
import 'budget_setup_form.dart';

/// Sets up a budget for a workspace that skipped the step during first-run
/// setup, using the categories it already has.
class BudgetSetupScreen extends StatefulWidget {
  const BudgetSetupScreen({super.key, required this.state});
  final AppState state;

  @override
  State<BudgetSetupScreen> createState() => _BudgetSetupScreenState();
}

class _BudgetSetupScreenState extends State<BudgetSetupScreen> {
  late final _model = OnboardingModel(today: widget.state.today())
    ..currency = widget.state.currency
    ..timezone = widget.state.settings.timezone;

  bool get _canSave =>
      (_model.takeHomePay?.isPositive ?? false) &&
      (_model.budgetMode == BudgetMode.categoryOnly ||
          _model.shareError == null);

  Future<void> _save() async {
    final state = widget.state;
    final budget = _model.buildBudget(state.chart.categories.toList());
    await state.savePlan(budget.plan!);
    for (final schedule in budget.schedules) {
      await state.saveSchedule(schedule);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your budget')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Use your take-home pay. The app does not estimate tax or '
            'superannuation.',
          ),
          const SizedBox(height: 8),
          BudgetSetupForm(
            model: _model,
            payAccounts: [
              for (final account in widget.state.chart.accounts)
                if (!account.type.isLiability && !account.archived) account,
            ],
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: const Text('Save budget'),
          ),
        ],
      ),
    );
  }
}
