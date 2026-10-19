import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../data/sync_controller.dart';
import 'bank_feeds_screen.dart';
import 'conflicts_screen.dart';
import 'extraction_consent_screen.dart';
import 'household_screen.dart';

/// Sync controls for the settings page.
class SyncSection extends StatelessWidget {
  const SyncSection({super.key, required this.controller});
  final SyncController controller;

  Future<void> _configure(BuildContext context) async {
    final current = controller.settings;
    final server = TextEditingController(text: current.serverUrl);
    final issuer = TextEditingController(text: current.issuer);
    final client = TextEditingController(text: current.clientId);
    final saved = await showDialog<SyncSettings>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync service'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: server,
              decoration: const InputDecoration(
                labelText: 'Service address',
                hintText: 'https://finance.example.com',
              ),
            ),
            TextField(
              controller: issuer,
              decoration: const InputDecoration(
                labelText: 'Sign-in provider address',
              ),
            ),
            TextField(
              controller: client,
              decoration: const InputDecoration(
                labelText: 'Application identifier',
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
            onPressed: () => Navigator.of(context).pop(
              SyncSettings(
                serverUrl: server.text.trim(),
                issuer: issuer.text.trim(),
                clientId: client.text.trim(),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != null) await controller.saveSettings(saved);
  }

  Future<void> _turnOn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await controller.isSignedIn) await controller.signIn();
      final remotes = await controller.remoteWorkspaces();
      if (!context.mounted) return;
      RemoteWorkspace? chosen;
      if (remotes.isNotEmpty) {
        chosen = await showDialog<RemoteWorkspace>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Which workspace?'),
            children: [
              for (final r in remotes)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(r),
                  child: Text('${r.name} (${r.currencyCode})'),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Create a new one for this device'),
              ),
            ],
          ),
        );
      }
      final preview = await controller.prepare(existing: chosen);
      if (!context.mounted) return;
      final message = switch (preview.action) {
        BootstrapAction.uploadLocal =>
          'This device\'s ${preview.pendingCommands} saved changes will be uploaded.',
        BootstrapAction.downloadRemote =>
          'The server\'s data will be downloaded to this device.',
        BootstrapAction.startEmpty => 'Both are empty; syncing starts now.',
        BootstrapAction.mergeRefused =>
          'Both this device and the server workspace already have data. They are never '
              'merged automatically: restore one from a backup or choose an empty workspace.',
      };
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Turn on sync?'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            if (preview.action != BootstrapAction.mergeRefused)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Turn on'),
              ),
          ],
        ),
      );
      if (confirmed == true) await controller.enable(preview);
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Sync could not be turned on: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final reviews = controller.state.store.openReviewItems();
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Sync service'),
              subtitle: Text(
                controller.settings.isComplete
                    ? controller.settings.serverUrl
                    : 'Not set up',
              ),
              onTap: () => _configure(context),
            ),
            if (!controller.isSynced)
              ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Turn on sync'),
                subtitle: const Text(
                  'Sign in, then choose or create a workspace',
                ),
                enabled: controller.settings.isComplete,
                onTap: () => _turnOn(context),
              )
            else ...[
              ListTile(
                leading: Icon(
                  controller.phase == SyncPhase.failed
                      ? Icons.sync_problem
                      : Icons.sync,
                ),
                title: Text(switch (controller.phase) {
                  SyncPhase.syncing => 'Syncing…',
                  SyncPhase.failed => controller.lastError ?? 'Sync paused',
                  _ =>
                    controller.lastSyncedAt == null
                        ? 'Not synced yet'
                        : 'Last synced ${TimeOfDay.fromDateTime(controller.lastSyncedAt!).format(context)}',
                }),
                subtitle: Text(
                  '${controller.state.unsyncedCount} changes waiting to upload',
                ),
                trailing: TextButton(
                  onPressed: controller.phase == SyncPhase.syncing
                      ? null
                      : controller.syncNow,
                  child: const Text('Sync now'),
                ),
              ),
              if (controller.phase == SyncPhase.failed &&
                  controller.lastError == 'Sign in again to continue syncing')
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('Sign in again'),
                  onTap: controller.signIn,
                ),
              ListTile(
                leading: const Icon(Icons.group_outlined),
                title: const Text('Household'),
                subtitle: const Text('Invite people to share chosen accounts'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => HouseholdScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: const Text('Bank feeds'),
                subtitle: const Text('Suggested entries from your bank'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BankFeedsScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.document_scanner_outlined),
                title: const Text('Cloud text recognition'),
                subtitle: const Text('Optional; off unless you allow it'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ExtractionConsentScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                subtitle: const Text('Your data stays on this device'),
                onTap: controller.signOut,
              ),
            ],
            if (reviews.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.call_split),
                title: Text('${reviews.length} changes need your decision'),
                subtitle: const Text(
                  'Edits made on two devices, or changes the server refused',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConflictsScreen(controller: controller),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
