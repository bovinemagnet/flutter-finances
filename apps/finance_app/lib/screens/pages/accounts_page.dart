import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/app_state.dart';
import '../../features/accounts/account_editor.dart';
import '../../features/plan/debt_payoff_screen.dart';
import '../../format/formatters.dart';

/// Accounts with balances, data source and last reconciliation (FIN 01,
/// FIN 02), plus statement reconciliation (FIN 08).
class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  Future<void> _edit(
    BuildContext context,
    AppState state, [
    Account? existing,
  ]) async {
    final edit = await Navigator.of(context).push<AccountEdit>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(existing == null ? 'Add account' : 'Edit account'),
          ),
          body: AccountEditor(
            currency: state.currency,
            today: state.today(),
            existing: existing,
            onSave: (edit) async => Navigator.of(context).pop(edit),
          ),
        ),
      ),
    );
    if (edit != null) await state.saveAccount(edit);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final ledger = state.ledger;
    final accounts = state.chart.accounts.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      body: ListView(
        children: [
          if (accounts.any((a) => a.type.isLiability && !a.archived))
            ListTile(
              leading: const Icon(Icons.trending_down),
              title: const Text('Plan paying off cards and loans'),
              subtitle: const Text(
                'Compare avalanche, snowball and minimum payments',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DebtPayoffScreen()),
              ),
            ),
          for (final account in accounts)
            ListTile(
              leading: Icon(
                account.type.isLiability
                    ? Icons.credit_card
                    : Icons.account_balance_outlined,
              ),
              title: Text(
                account.name + (account.archived ? ' (archived)' : ''),
              ),
              subtitle: Text(
                [
                  accountTypeLabels[account.type]!,
                  'source: ${account.dataSource}',
                  account.lastReconciledOn == null
                      ? 'never reconciled'
                      : 'reconciled to ${formatDate(account.lastReconciledOn!)}',
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatMoney(ledger.displayBalance(account.id))),
                      Text(
                        account.type.isLiability ? 'owed' : 'calculated',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Actions for ${account.name}',
                    onSelected: (action) => action == 'edit'
                        ? _edit(context, state, account)
                        : Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ReconcileScreen(
                                state: state,
                                account: account,
                              ),
                            ),
                          ),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(
                        value: 'reconcile',
                        child: Text('Reconcile'),
                      ),
                    ],
                  ),
                ],
              ),
              onTap: () => _edit(context, state, account),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'account',
        onPressed: () => _edit(context, state),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
    );
  }
}

/// Tick the entries on a statement and see the difference. Completing needs
/// a zero difference or an explicitly confirmed adjustment; missing entries
/// are never invented.
class ReconcileScreen extends StatefulWidget {
  const ReconcileScreen({
    super.key,
    required this.state,
    required this.account,
  });
  final AppState state;
  final Account account;

  @override
  State<ReconcileScreen> createState() => _ReconcileScreenState();
}

class _ReconcileScreenState extends State<ReconcileScreen> {
  late LocalDate _date = widget.state.today();
  final _balance = TextEditingController();
  late final Set<String> _cleared = {
    for (final j in widget.state.ledger.journalsForAccount(widget.account.id))
      if (widget.account.lastReconciledOn != null &&
          j.effectiveDate <= widget.account.lastReconciledOn!)
        j.id,
  };

  Money? get _statement {
    try {
      return Money.parse(_balance.text, widget.state.currency);
    } on FormatException {
      return null;
    }
  }

  Future<void> _complete() async {
    final state = widget.state;
    final statement = _statement;
    if (statement == null) return;
    final session = Reconciliation(
      accountId: widget.account.id,
      statementDate: _date,
      statementBalance: statement,
      clearedJournalIds: _cleared,
    );
    final ledger = state.ledger;
    final difference = session.difference(ledger);
    var confirm = false;
    if (!difference.isZero) {
      confirm =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('The statement does not match'),
              content: Text(
                'Difference ${formatMoney(difference)}. You can go '
                'back and find the missing entries, or record a balance '
                'adjustment of this amount.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Go back'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Record adjustment'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirm) return;
    }
    final result = session.complete(
      ledger,
      JournalFactory(state.chart),
      confirmAdjustment: confirm,
    );
    if (result.adjustment != null) {
      await state.post(
        TransactionDraft(
          type: TransactionType.adjustment,
          accountId: widget.account.id,
          amount: difference,
          effectiveDate: _date,
          notes: 'Reconciliation adjustment',
        ),
      );
    }
    await state.saveAccount(
      AccountEdit(
        widget.account.copyWith(lastReconciledOn: _date),
        null,
        _date,
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ledger = widget.state.ledger;
    final entries =
        ledger
            .journalsForAccount(widget.account.id)
            .where((j) => j.status.inPostedLedger && j.effectiveDate <= _date)
            .toList()
          ..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
    final statement = _statement;
    final session = statement == null
        ? null
        : Reconciliation(
            accountId: widget.account.id,
            statementDate: _date,
            statementBalance: statement,
            clearedJournalIds: _cleared,
          );
    return Scaffold(
      appBar: AppBar(title: Text('Reconcile ${widget.account.name}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _balance,
                    decoration: InputDecoration(
                      labelText: widget.account.type.isLiability
                          ? 'Statement amount owed'
                          : 'Statement closing balance',
                      prefixText: r'$ ',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime(_date.year, _date.month, _date.day),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setState(() => _date = LocalDate.fromDateTime(picked));
                    }
                  },
                  child: Text('as at ${formatDate(_date)}'),
                ),
              ],
            ),
          ),
          if (session != null)
            Semantics(
              liveRegion: true,
              child: Text(
                'Difference ${formatMoney(session.difference(ledger))}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                for (final j in entries)
                  CheckboxListTile(
                    value: _cleared.contains(j.id),
                    onChanged: (v) => setState(
                      () => v == true
                          ? _cleared.add(j.id)
                          : _cleared.remove(j.id),
                    ),
                    title: Text(j.payee ?? j.notes ?? j.type.name),
                    subtitle: Text(formatDate(j.effectiveDate)),
                    secondary: Text(
                      formatMoney(j.amountFor(widget.account.id)!),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: statement == null ? null : _complete,
              child: const Text('Finish reconciliation'),
            ),
          ),
        ],
      ),
    );
  }
}
