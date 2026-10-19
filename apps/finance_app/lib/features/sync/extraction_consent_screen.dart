import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../data/sync_controller.dart';

/// Consent to optional cloud text recognition of receipts (AUTO 02). It is
/// separate from sync consent and names the provider and retention shown.
class ExtractionConsentScreen extends StatefulWidget {
  const ExtractionConsentScreen({super.key, required this.controller});
  final SyncController controller;

  @override
  State<ExtractionConsentScreen> createState() =>
      _ExtractionConsentScreenState();
}

class _ExtractionConsentScreenState extends State<ExtractionConsentScreen> {
  late Future<ExtractionConsent> _load = _fetch();

  ExtractionClient get _extraction => widget.controller.extraction;

  Future<ExtractionConsent> _fetch() =>
      _extraction.consent(widget.controller.workspaceId);

  Future<void> _change(ExtractionConsent current, bool grant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          grant ? 'Allow cloud text recognition?' : 'Stop cloud recognition?',
        ),
        content: Text(
          grant
              ? 'Receipt images you sync are sent to '
                    '${current.offeredProvider} to read their text. '
                    'Retention: ${current.offeredRetention}. The text only '
                    'fills in suggestions you review.'
              : 'Nothing more is sent, and the text already recognised is '
                    'deleted from the service.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(grant ? 'Allow' : 'Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final workspaceId = widget.controller.workspaceId;
    setState(() {
      _load = grant
          ? _extraction.grant(workspaceId, current)
          : _extraction.withdraw(workspaceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud text recognition')),
      body: FutureBuilder(
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
                error is SyncHttpException &&
                        error.errorCode == 'OWNER_REQUIRED'
                    ? 'Only the household owner can change this.'
                    : 'Could not load this setting: $error',
              ),
            );
          }
          final consent = snapshot.requireData;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Receipts are read on this device. Where this device cannot '
                'read them, the sync service can, with your consent.',
              ),
              const SizedBox(height: 16),
              if (!consent.available)
                const Text(
                  'This sync service does not offer cloud text recognition.',
                )
              else ...[
                ListTile(
                  title: const Text('Provider'),
                  subtitle: Text(consent.offeredProvider ?? ''),
                ),
                ListTile(
                  title: const Text('How long it keeps receipts'),
                  subtitle: Text(consent.offeredRetention ?? ''),
                ),
                SwitchListTile(
                  title: const Text('Allow cloud text recognition'),
                  value: consent.granted,
                  onChanged: (value) => _change(consent, value),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
