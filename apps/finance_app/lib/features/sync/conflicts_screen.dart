import 'dart:convert';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../data/sync_controller.dart';
import '../../format/formatters.dart';
import '../transactions/transaction_form.dart';
import '../transactions/transaction_form_model.dart';

const _kindText = {
  ReviewKind.conflict: 'Changed on another device',
  ReviewKind.rejected: 'Refused by the server',
  ReviewKind.deletedRemotely: 'Deleted on another device',
};

/// Conflicts are never settled by last write wins (SYNC 03): the user keeps
/// their version (sent again as a fresh, validated change), keeps the
/// server's, or combines them into a new entry.
class ConflictsScreen extends StatelessWidget {
  const ConflictsScreen({super.key, required this.controller});
  final SyncController controller;

  String _describe(Map<String, Object?>? state, Currency currency) {
    if (state == null) return 'Deleted';
    final amount = state['amountMinor'];
    final parts = [
      if (state['payee'] != null) state['payee'],
      if (state['name'] != null) state['name'],
      if (amount is int) formatMoney(Money(amount, currency)),
      if (state['effectiveDate'] != null) state['effectiveDate'],
    ];
    return parts.isEmpty
        ? const JsonEncoder.withIndent(' ').convert(state)
        : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Scaffold(
      appBar: AppBar(title: const Text('Changes to decide')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final items = state.store.openReviewItems();
          if (items.isEmpty) {
            return const Center(child: Text('Nothing to decide'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final item in items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _kindText[item.kind]!,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (item.fields.isNotEmpty)
                          Text('Fields: ${item.fields.join(', ')}'),
                        if (item.errors.isNotEmpty)
                          Text('Reason: ${item.errors.join(', ')}'),
                        const SizedBox(height: 8),
                        Text(
                          'Yours: ${_describe(item.localState, state.currency)}',
                        ),
                        Text(
                          'Server: ${_describe(item.serverState, state.currency)}',
                        ),
                        OverflowBar(
                          alignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () async {
                                await state.store.dismissReview(item.id);
                                state.refresh();
                              },
                              child: const Text('Keep server version'),
                            ),
                            if (item.kind != ReviewKind.rejected)
                              TextButton(
                                onPressed: () async {
                                  await state.store.resolveKeepLocal(item.id);
                                  state.refresh();
                                  await controller.syncNow();
                                },
                                child: const Text('Keep mine'),
                              ),
                            if (item.entity.type == 'journal' &&
                                item.serverState != null)
                              TextButton(
                                onPressed: () => _combine(context, item),
                                child: const Text('Edit a combined version'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _combine(BuildContext context, ReviewItem item) async {
    final state = controller.state;
    final server = journalFromJson(item.serverState!, state.currency);
    final model = TransactionFormModel.fromJournal(
      state.chart,
      server,
      today: state.today(),
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Combined version')),
          body: TransactionForm(
            model: model,
            onSave: (draft) async {
              await state.store.resolveWithTransaction(item.id, draft);
              state.refresh();
              await controller.syncNow();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ),
      ),
    );
  }
}
