import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../format/formatters.dart';

/// Detailed holdings of an investment or super account (P1): units held,
/// dated prices and a valuation the user can apply as a balance adjustment.
class HoldingsScreen extends StatelessWidget {
  const HoldingsScreen({super.key, required this.accountId});
  final String accountId;

  Future<Map<String, String>?> _ask(
    BuildContext context,
    String title,
    List<String> labels,
  ) {
    final controllers = [for (final _ in labels) TextEditingController()];
    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, label) in labels.indexed)
              TextField(
                controller: controllers[i],
                decoration: InputDecoration(labelText: label),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop({
              for (final (i, label) in labels.indexed)
                label: controllers[i].text.trim(),
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final account = state.chart.account(accountId);
    final valuation = state.valuation(accountId);
    final proposal = state.valuationProposal(accountId);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } on FormatException {
        messenger.showSnackBar(
          const SnackBar(content: Text('Check the numbers entered')),
        );
      } on Exception catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text('${account.name} holdings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Value ${formatMoney(valuation.total)}'),
            subtitle: Text(
              'Recorded balance ${formatMoney(proposal.recordedBalance)}'
              '${valuation.isComplete ? '' : ' · some holdings have no price'}',
            ),
            trailing: proposal.draft == null
                ? null
                : FilledButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Update the account value?'),
                          content: Text(
                            'Records a balance adjustment of '
                            '${formatMoney(proposal.draft!.amount, signed: true)}.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('Update'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) await state.post(proposal.draft!);
                    },
                    child: const Text('Update value'),
                  ),
          ),
          const Divider(),
          for (final h in valuation.holdings)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${h.holding.securityCode} · ${h.holding.name}'),
              subtitle: Text(
                '${formatUnits(h.units)} units'
                '${h.price == null ? ' · no price yet' : ' at ${formatMoney(h.price!.price)} on ${formatDate(h.price!.date)}'}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(h.value == null ? '–' : formatMoney(h.value!)),
                  PopupMenuButton<String>(
                    tooltip: 'Actions for ${h.holding.securityCode}',
                    onSelected: (action) => guarded(() async {
                      if (action == 'price') {
                        final values = await _ask(
                          context,
                          'Price of ${h.holding.securityCode}',
                          ['Price per unit', 'Date (YYYY-MM-DD)'],
                        );
                        if (values == null) return;
                        await state.recordPrice(
                          SecurityPrice(
                            securityCode: h.holding.securityCode,
                            date: values['Date (YYYY-MM-DD)']!.isEmpty
                                ? state.today()
                                : LocalDate.parse(values['Date (YYYY-MM-DD)']!),
                            price: Money.parse(
                              values['Price per unit']!,
                              state.currency,
                            ),
                          ),
                        );
                      } else {
                        final values = await _ask(
                          context,
                          action == 'buy' ? 'Units bought' : 'Units sold',
                          ['Units'],
                        );
                        if (values == null) return;
                        final units = parseUnits(values['Units']!);
                        await state.recordHoldingEvent(
                          action == 'buy'
                              ? HoldingEvent.buy(
                                  id: newId(),
                                  holdingId: h.holding.id,
                                  date: state.today(),
                                  units: units,
                                )
                              : HoldingEvent.sell(
                                  id: newId(),
                                  holdingId: h.holding.id,
                                  date: state.today(),
                                  units: units,
                                ),
                        );
                      }
                    }),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'buy',
                        child: Text('Record units bought'),
                      ),
                      PopupMenuItem(
                        value: 'sell',
                        child: Text('Record units sold'),
                      ),
                      PopupMenuItem(
                        value: 'price',
                        child: Text('Record a price'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (valuation.holdings.isEmpty)
            const Text(
              'Add the funds or shares held in this account to value it.',
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'holding',
        icon: const Icon(Icons.add),
        label: const Text('Add holding'),
        onPressed: () => guarded(() async {
          final values = await _ask(context, 'New holding', ['Code', 'Name']);
          if (values == null || values['Code']!.isEmpty) return;
          await state.saveHolding(
            Holding(
              id: newId(),
              securityCode: values['Code']!.toUpperCase(),
              name: values['Name']!.isEmpty ? values['Code']! : values['Name']!,
              accountId: accountId,
            ),
          );
        }),
      ),
    );
  }
}
