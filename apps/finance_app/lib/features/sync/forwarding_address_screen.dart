import 'package:finance_core/finance_core.dart' show LocalDate;
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/sync_controller.dart';
import '../../format/formatters.dart';

typedef _Loaded = ({InboundAddress? address, List<InboundNotice> recent});

const _outcomes = {
  'documents': 'Attachments received',
  'no_attachment': 'No attachment',
  'rejected': 'Nothing could be kept',
  'rate_limited': 'Over the daily limit',
  'failed': 'Could not be processed',
  'processing': 'Still being handled',
};

/// Turns on, shows, replaces and turns off the member's private address for
/// forwarding receipts by email. Nothing a forwarded email brings is entered
/// until it is reviewed.
class ForwardingAddressScreen extends StatefulWidget {
  const ForwardingAddressScreen({super.key, required this.controller});
  final SyncController controller;

  @override
  State<ForwardingAddressScreen> createState() =>
      _ForwardingAddressScreenState();
}

class _ForwardingAddressScreenState extends State<ForwardingAddressScreen> {
  InboundMailClient get _client => widget.controller.inboundMail;
  String get _workspaceId => widget.controller.workspaceId;

  late Future<_Loaded> _load = _fetch();

  Future<_Loaded> _fetch() async {
    final address = await _client.address(_workspaceId);
    List<InboundNotice> recent;
    try {
      recent = (await _client.inbox(_workspaceId)).recent;
    } on Exception {
      recent = const [];
    }
    return (address: address, recent: recent);
  }

  void _reload() => setState(() {
    _load = _fetch();
  });

  Future<void> _run(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
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
    'READ_ONLY' => 'Viewers cannot forward receipts to this workspace.',
    'INBOUND_MAIL_UNAVAILABLE' =>
      'Email forwarding is not offered by this service.',
    _ => e.errorCode ?? 'The service refused the request',
  };

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _replace() async {
    final confirmed = await _confirm(
      title: 'Replace this address?',
      message:
          'Mail sent to your current address will be dropped, and the sender '
          'is not told. Update any forwarding rules that use it.',
      action: 'Replace',
    );
    if (confirmed) {
      await _run(() => _client.createOrReplaceAddress(_workspaceId));
    }
  }

  Future<void> _turnOff() async {
    final confirmed = await _confirm(
      title: 'Turn off forwarding?',
      message:
          'Mail sent to this address will be dropped, and the sender is not '
          'told. Documents already waiting can still be collected.',
      action: 'Turn off',
    );
    if (confirmed) await _run(() => _client.revokeAddress(_workspaceId));
  }

  Future<void> _copy(String address) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: address));
    messenger.showSnackBar(const SnackBar(content: Text('Address copied')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Forward receipts by email')),
    body: FutureBuilder<_Loaded>(
      future: _load,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = snapshot.error;
        if (error != null) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              error is SyncHttpException ? _explain(error) : 'Could not reach the service. Try again when you are online.',
            ),
          );
        }
        final loaded = snapshot.requireData;
        return _content(context, loaded.address, loaded.recent);
      },
    ),
  );

  Widget _content(
    BuildContext context,
    InboundAddress? address,
    List<InboundNotice> recent,
  ) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Forward an email to your private address, and its image and PDF '
          'attachments arrive here as receipts for you to review. Nothing is '
          'entered until you do. Details from PDFs are entered by hand for now.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Emails pass through an outside email service and your sync service. '
          'The body of each email is discarded; the attachments, sender and '
          'subject are kept until collected.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Once collected, a receipt is shared with your workspace, like any '
          'other receipt.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Your devices collect whenever they sync. Attachments not collected '
          'within 30 days expire. Each can be up to 20 MB.',
        ),
        const SizedBox(height: 24),
        if (address == null)
          FilledButton(
            onPressed: () =>
                _run(() => _client.createOrReplaceAddress(_workspaceId)),
            child: const Text('Turn on'),
          )
        else ...[
          Text('Your address', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: SelectableText(address.address)),
              IconButton(
                tooltip: 'Copy address',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(address.address),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Keep it private: anything sent to it arrives in your receipts.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _replace,
                child: const Text('Replace address'),
              ),
              TextButton(onPressed: _turnOff, child: const Text('Turn off')),
            ],
          ),
        ],
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Recent emails', style: theme.textTheme.titleSmall),
          for (final email in recent)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                email.sender.isEmpty ? 'Unknown sender' : email.sender,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_outcomes[email.outcome] ?? 'Could not be processed'} · '
                '${formatDate(LocalDate.fromDateTime(email.receivedAt.toLocal()))}',
              ),
            ),
        ],
      ],
    );
  }
}
