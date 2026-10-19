import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../data/bank_feed_service.dart';
import '../../data/sync_controller.dart';
import '../../screens/editors.dart';
import '../transactions/transaction_form.dart';

/// The only provider until the Consumer Data Right provider is chosen
/// (BANK 01); the service offers it only where its sandbox is enabled.
const bankFeedProvider = 'sandbox';

const _purpose = 'Suggest entries from my bank transactions';

/// Bank connections, their health and the transactions they suggest
/// (BANK 01-03). Suggestions are entered only after review.
class BankFeedsScreen extends StatefulWidget {
  const BankFeedsScreen({super.key, required this.controller});
  final SyncController controller;

  @override
  State<BankFeedsScreen> createState() => _BankFeedsScreenState();
}

typedef _Feed = ({BankConnection connection, List<BankProposal> proposals});

class _BankFeedsScreenState extends State<BankFeedsScreen> {
  late final _service = BankFeedService(
    state: widget.controller.state,
    client: widget.controller.bankFeeds,
    pushChanges: widget.controller.syncNow,
  );
  late Future<List<_Feed>> _load = _fetch();

  BankFeedClient get _client => _service.client;

  Future<List<_Feed>> _fetch() async => [
    for (final connection in await _client.connections())
      (
        connection: connection,
        proposals: connection.consentStatus == BankConsentStatus.revoked
            ? const <BankProposal>[]
            : await _client.proposals(connection.id, status: 'all'),
      ),
  ];

  void _reload() => setState(() {
    _load = _fetch();
  });

  Future<void> _run(Future<void> Function() action, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on SyncHttpException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_explain(e))));
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not reach the service: $e')),
      );
    }
    if (mounted) _reload();
  }

  String _explain(SyncHttpException e) => switch (e.errorCode) {
    'BANK_FEEDS_UNAVAILABLE' || 'UNKNOWN_PROVIDER' =>
      'Bank connections are not offered by this service yet. Manual entry '
          'and statement import still work.',
    'CONSENT_EXPIRED' => 'Consent has expired; reconnect to continue.',
    'CONNECTION_REVOKED' => 'This connection was disconnected.',
    'PROPOSAL_DECIDED' => 'Someone already decided on this transaction.',
    'JOURNAL_NOT_FOUND' =>
      'The entry is saved on this device and is marked as accepted once '
          'it has synced.',
    _ => e.errorCode ?? 'The service refused the request',
  };

  Future<void> _connect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect a bank?'),
        content: const Text(
          'You give consent at your bank, never here: this app never asks '
          'for your bank password. It reads your account names and '
          'transactions to suggest entries, and nothing is entered until '
          'you review it. You can disconnect at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => _client.connect(provider: bankFeedProvider, purpose: _purpose),
      'Connected; transactions arrive shortly',
    );
  }

  Future<void> _disconnect(BankConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect ${connection.institutionName}?'),
        content: const Text(
          'Consent is withdrawn and no more transactions are collected. '
          'Entries you already made stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => _client.revoke(connection.id), 'Disconnected');
  }

  Future<void> _review(_Feed feed, BankProposal proposal) async {
    final connectionId = feed.connection.id;
    if (_service.enteredFrom(proposal) != null) {
      return _run(
        () => _service.finish(connectionId, proposal),
        'Marked as entered',
      );
    }
    if (proposal.kind == BankProposalKind.reversal) {
      return _reviewReversal(feed, proposal);
    }
    final settling = _service.pendingEntryFor(proposal, feed.proposals);
    final form = _service.formFor(proposal, settling: settling);
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(
              settling == null ? 'Review bank transaction' : 'Settle entry',
            ),
          ),
          body: TransactionForm(
            model: form,
            onCancel: () => Navigator.of(context).pop(false),
            onSave: (draft) async {
              final navigator = Navigator.of(context);
              await _run(
                () => _service.accept(
                  connectionId,
                  proposal,
                  draft,
                  settling: settling,
                ),
                'Entered',
              );
              navigator.pop(true);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _reviewReversal(_Feed feed, BankProposal proposal) async {
    final related = feed.proposals
        .where((p) => p.recordId == proposal.relatedRecordId)
        .firstOrNull;
    final original = related?.journalId == null
        ? null
        : widget.controller.state.store.journal(related!.journalId!);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The bank reversed a transaction'),
        content: Text(
          original == null
              ? 'Nothing was entered for the original transaction, so there '
                    'is nothing to correct.'
              : 'You entered the original transaction. Delete or correct '
                    'that entry, then dismiss this suggestion.',
        ),
        actions: [
          if (original != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop('open'),
              child: const Text('Open the entry'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('dismiss'),
            child: const Text('Dismiss suggestion'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'open') {
      await openTransactionEditor(context, journal: original);
    } else if (choice == 'dismiss') {
      await _run(
        () => _service.dismiss(feed.connection.id, proposal),
        'Dismissed',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bank feeds'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder(
        future: _load,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final feeds = snapshot.data ?? const <_Feed>[];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'A bank feed suggests entries from your bank\'s transactions. '
                'Feeds are not real-time: they refresh from time to time.',
              ),
              if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    snapshot.error is SyncHttpException
                        ? _explain(snapshot.error! as SyncHttpException)
                        : 'Could not load bank feeds: ${snapshot.error}',
                  ),
                ),
              for (final feed in feeds) _connectionCard(context, feed),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.account_balance_outlined),
                label: const Text('Connect a bank'),
                onPressed: _connect,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _connectionCard(BuildContext context, _Feed feed) {
    final c = feed.connection;
    final theme = Theme.of(context);
    final open = feed.proposals.where((p) => p.proposalStatus == 'open');
    final lastRefresh = c.lastSuccessfulRefreshAt;
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.account_balance_outlined),
            title: Text(c.institutionName),
            subtitle: Text(
              [
                switch (c.consentStatus) {
                  BankConsentStatus.active => 'Connected',
                  BankConsentStatus.pending =>
                    'Waiting for consent at the bank',
                  BankConsentStatus.expired => 'Consent expired',
                  BankConsentStatus.revoked => 'Disconnected',
                },
                if (lastRefresh != null)
                  'last updated ${LocalDate.fromDateTime(lastRefresh.toLocal())}',
              ].join(' · '),
            ),
          ),
          if (c.stale && c.consentStatus == BankConsentStatus.active)
            ListTile(
              leading: Icon(
                Icons.warning_amber,
                color: theme.colorScheme.error,
              ),
              title: const Text('This feed is out of date'),
              subtitle: const Text(
                'It has not refreshed recently, so recent transactions may be '
                'missing. Refresh it or reconnect.',
              ),
            ),
          if (c.errorCode != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(
                c.errorCode == 'RATE_LIMITED'
                    ? 'The bank asked us to slow down; it retries automatically'
                    : 'The last refresh failed (${c.errorCode})',
              ),
            ),
          for (final proposal in open)
            ListTile(
              title: Text(proposal.description),
              subtitle: Text(
                [
                  proposal.date,
                  if (proposal.pending) 'pending',
                  switch (proposal.kind) {
                    BankProposalKind.settlesPending =>
                      'completes a pending one',
                    BankProposalKind.reversal => 'reversal',
                    BankProposalKind.newTransaction => null,
                  },
                  if (_service.enteredFrom(proposal) != null)
                    'entered, tap to finish',
                ].nonNulls.join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Money(
                      proposal.amountMinor,
                      widget.controller.state.currency,
                    ).toDecimalString(),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close),
                    onPressed: () => _run(
                      () => _service.dismiss(c.id, proposal),
                      'Dismissed',
                    ),
                  ),
                ],
              ),
              onTap: () => _review(feed, proposal),
            ),
          if (c.consentStatus != BankConsentStatus.revoked)
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                if (c.consentStatus == BankConsentStatus.active)
                  TextButton(
                    onPressed: () => _run(
                      () => _client.refresh(c.id),
                      'Refreshing; new transactions arrive shortly',
                    ),
                    child: const Text('Refresh'),
                  ),
                if (c.consentStatus == BankConsentStatus.expired || c.stale)
                  TextButton(
                    onPressed: () =>
                        _run(() => _client.reconnect(c.id), 'Reconnected'),
                    child: const Text('Reconnect'),
                  ),
                TextButton(
                  onPressed: () => _disconnect(c),
                  child: const Text('Disconnect'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
