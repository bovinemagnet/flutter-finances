import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../format/formatters.dart';

const strategyLabels = {
  PayoffStrategy.avalanche: 'Highest interest first',
  PayoffStrategy.snowball: 'Smallest balance first',
  PayoffStrategy.minimumOnly: 'Minimum payments only',
};

/// Compares ways of paying off cards and loans (P1 debt payoff). It only
/// projects; payments are still recorded as ordinary transfers.
class DebtPayoffScreen extends StatefulWidget {
  const DebtPayoffScreen({super.key});

  @override
  State<DebtPayoffScreen> createState() => _DebtPayoffScreenState();
}

class _DebtPayoffScreenState extends State<DebtPayoffScreen> {
  final _extra = TextEditingController();

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  Future<void> _editTerms(Account account, DebtTerms? existing) async {
    final state = AppScope.of(context);
    final rate = TextEditingController(
      text: existing == null
          ? ''
          : (existing.annualRateBasisPoints / 100).toString(),
    );
    final minimum = TextEditingController(
      text: existing?.minimumPayment.toDecimalString() ?? '',
    );
    final terms = await showDialog<DebtTerms>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(account.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rate,
              decoration: const InputDecoration(
                labelText: 'Interest rate per year',
                suffixText: '%',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            TextField(
              controller: minimum,
              decoration: const InputDecoration(
                labelText: 'Minimum monthly payment',
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
                // Rates are held as integer basis points, never as doubles.
                final basisPoints = parseMinor(rate.text, 2);
                Navigator.of(context).pop(
                  DebtTerms(
                    id: existing?.id ?? newId(),
                    accountId: account.id,
                    annualRateBasisPoints: basisPoints,
                    minimumPayment: Money.parse(minimum.text, state.currency),
                  ),
                );
              } on FormatException {
                return;
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (terms != null) await state.saveDebtTerms(terms);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final terms = {for (final t in state.debtTerms) t.accountId: t};
    final debts = state.chart.accounts
        .where((a) => a.type.isLiability && !a.archived)
        .toList();
    Money? extra;
    try {
      extra = _extra.text.trim().isEmpty
          ? null
          : Money.parse(_extra.text, state.currency);
    } on FormatException {
      extra = null;
    }
    DebtPayoffComparison? comparison;
    String? problem;
    try {
      comparison = state.debtPayoff(extraMonthly: extra);
    } on Exception catch (e) {
      problem = '$e';
    } on ArgumentError catch (e) {
      problem = e.message.toString();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Paying off debt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final account in debts)
            ListTile(
              title: Text(account.name),
              subtitle: Text(
                terms[account.id] == null
                    ? 'Add the interest rate and minimum payment'
                    : '${terms[account.id]!.annualRateBasisPoints / 100}% a year, '
                          'minimum ${formatMoney(terms[account.id]!.minimumPayment)}',
              ),
              trailing: Text(
                formatMoney(state.ledger.displayBalance(account.id)),
              ),
              onTap: () => _editTerms(account, terms[account.id]),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _extra,
            decoration: const InputDecoration(
              labelText: 'Extra I can pay each month',
              prefixText: r'$ ',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (problem != null) Text(problem),
          if (comparison == null && problem == null)
            const Text(
              'Add terms for at least one card or loan with a balance.',
            ),
          if (comparison != null)
            DataTable(
              columns: const [
                DataColumn(label: Text('Approach')),
                DataColumn(label: Text('Debt free')),
                DataColumn(label: Text('Interest'), numeric: true),
              ],
              rows: [
                for (final plan in [
                  comparison.avalanche,
                  comparison.snowball,
                  comparison.minimumOnly,
                ])
                  DataRow(
                    cells: [
                      DataCell(Text(strategyLabels[plan.strategy]!)),
                      DataCell(Text(_debtFree(plan))),
                      DataCell(Text(formatMoney(plan.totalInterest))),
                    ],
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _debtFree(DebtPayoffPlan plan) {
    final dates = plan.payoffDates.values;
    if (dates.any((d) => d == null)) return 'Not within 50 years';
    final last = dates.whereType<LocalDate>().reduce((a, b) => a > b ? a : b);
    return formatDate(last);
  }
}
