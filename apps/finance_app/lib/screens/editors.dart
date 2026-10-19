import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../features/transactions/transaction_form.dart';
import '../features/transactions/transaction_form_model.dart';

/// Opens the entry form for a new entry or an ordinary edit, then offers
/// undo for the saved change (UX 02).
Future<void> openTransactionEditor(
  BuildContext context, {
  TransactionType type = TransactionType.expense,
  Journal? journal,
  TransactionFormModel? prefilled,
}) async {
  final state = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final model =
      prefilled ??
      (journal == null
          ? (TransactionFormModel(state.chart, today: state.today())
              ..type = type)
          : TransactionFormModel.fromJournal(
              state.chart,
              journal,
              today: state.today(),
            ));
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(journal == null ? 'New entry' : 'Edit entry'),
          actions: [
            if (journal != null)
              IconButton(
                tooltip: 'Delete entry',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete this entry?'),
                      content: Text(
                        journal.status.inPostedLedger
                            ? 'The entry is reversed so that history and reports stay correct.'
                            : 'The draft is removed.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Keep'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !context.mounted) return;
                  await state.correct(journal.id, null);
                  if (context.mounted) Navigator.of(context).pop(true);
                },
              ),
          ],
        ),
        body: TransactionForm(
          model: model,
          onCancel: () => Navigator.of(context).pop(false),
          onSave: (draft) async {
            if (journal == null) {
              await state.post(draft);
            } else {
              await state.correct(journal.id, draft);
            }
            if (context.mounted) Navigator.of(context).pop(true);
          },
        ),
      ),
    ),
  );
  if (saved == true) {
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Saved on this device'),
        action: SnackBarAction(label: 'Undo', onPressed: state.undo),
      ),
    );
  }
}
