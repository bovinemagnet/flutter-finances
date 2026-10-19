import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../features/budget/budget_view.dart';
import '../../features/goals/goals_view.dart';
import '../../format/formatters.dart';

class BudgetPage extends StatefulWidget {
  const BudgetPage({super.key, required this.onOpenEntries});
  final ValueChanged<List<String>> onOpenEntries;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  LocalDate? _at;

  Future<void> _addGoal() async {
    final state = AppScope.of(context);
    final name = TextEditingController();
    final target = TextEditingController();
    final goal = await showDialog<Goal>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New savings goal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: target,
              decoration: const InputDecoration(
                labelText: 'Target',
                prefixText: r'$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                Navigator.of(context).pop(
                  Goal(
                    id: newId(),
                    name: name.text.trim().isEmpty
                        ? 'Savings goal'
                        : name.text.trim(),
                    target: Money.parse(target.text, state.currency),
                  ),
                );
              } on FormatException {
                return;
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (goal != null) await state.saveGoal(goal);
  }

  Future<void> _allocate(GoalProgress progress) async {
    final state = AppScope.of(context);
    final amount = TextEditingController();
    final value = await showDialog<Money>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Allocate to ${progress.goal.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Allocating counts money towards the goal. Moving money '
              'to a savings account is a separate transfer.',
            ),
            TextField(
              controller: amount,
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: r'$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                Navigator.of(context)
                    .pop(Money.parse(amount.text, state.currency));
              } on FormatException {
                return;
              }
            },
            child: const Text('Allocate'),
          ),
        ],
      ),
    );
    if (value != null && value.isPositive) {
      await state.allocateToGoal(progress.goal.id, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final at = _at ?? state.today();
    final evaluation = state.budgetEvaluation(at: at);
    String nameFor(String id) {
      if (state.chart.hasCategory(id)) return state.chart.category(id).name;
      for (final g in state.goals) {
        if (g.id == id) return g.name;
      }
      if (state.chart.hasAccount(id)) return state.chart.account(id).name;
      return id;
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Budget'),
              Tab(text: 'Goals'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                evaluation == null
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No budget yet. Set one up from your take-home pay in Settings.',
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Previous period',
                                icon: const Icon(Icons.chevron_left),
                                onPressed: () => setState(
                                  () =>
                                      _at = evaluation.period.start.addDays(-1),
                                ),
                              ),
                              Text(formatDate(evaluation.period.start)),
                              IconButton(
                                tooltip: 'Next period',
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => setState(
                                  () => _at = evaluation.period.end.addDays(1),
                                ),
                              ),
                            ],
                          ),
                          Expanded(
                            child: BudgetView(
                              evaluation: evaluation,
                              nameFor: nameFor,
                              onOpenEntries: widget.onOpenEntries,
                            ),
                          ),
                        ],
                      ),
                Scaffold(
                  body: GoalsView(
                    progress: state.goalProgress(),
                    onOpen: _allocate,
                  ),
                  floatingActionButton: FloatingActionButton.extended(
                    heroTag: 'goal',
                    onPressed: _addGoal,
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('New goal'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
