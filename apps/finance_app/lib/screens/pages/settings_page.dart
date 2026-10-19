import 'dart:io';

import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/entity_types.dart';
import '../../features/imports/import_screen.dart';
import '../../features/settings/rules_screen.dart';
import '../../format/formatters.dart';

/// Data, security, planning preferences and device information.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.syncSection});

  /// Sync controls, supplied by the host so this page stays testable.
  final Widget? syncSection;

  Future<String?> _askSecret(
    BuildContext context,
    String title,
    String explanation,
  ) {
    final secret = TextEditingController();
    final repeat = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(explanation),
            TextField(
              controller: secret,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Recovery secret'),
            ),
            TextField(
              controller: repeat,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Repeat recovery secret',
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
              if (secret.text.length >= 10 && secret.text == repeat.text) {
                Navigator.of(context).pop(secret.text);
              }
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<void> _backup(BuildContext context) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final secret = await _askSecret(
      context,
      'Encrypted backup',
      'The backup is encrypted with this secret (at least 10 characters). '
          'Keep it safe: without it the backup cannot be opened.',
    );
    if (secret == null) return;
    final path = await services.fileImporter.chooseSaveLocation(
      'finances-${state.today()}.fsbackup',
    );
    if (path == null) return;
    try {
      final summary = await exportBackup(
        state.store,
        File(path),
        recoverySecret: secret,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Backup saved: ${summary.toString()}')),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _exportCsv(BuildContext context) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final path = await services.fileImporter.chooseSaveLocation(
      'transactions-${state.today()}.csv',
    );
    if (path == null) return;
    await File(
      path,
    ).writeAsString(exportTransactionsCsv(state.ledger.journals, state.chart));
    messenger.showSnackBar(
      const SnackBar(content: Text('Transactions exported')),
    );
  }

  Future<void> _import(BuildContext context) async {
    final services = AppScope.servicesOf(context);
    final file = await services.fileImporter.pickStatement();
    if (file == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ImportScreen(bytes: file.bytes, fileName: file.fileName),
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final directory = AppScope.servicesOf(context).workspaceDirectory;
    final messenger = ScaffoldMessenger.of(context);
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password (10 or more characters)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(next.text.length >= 10),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FinanceStore.changeWorkspacePassword(
        directory,
        current.text,
        next.text,
      );
      messenger.showSnackBar(const SnackBar(content: Text('Password changed')));
    } on WrongPasswordException {
      messenger.showSnackBar(
        const SnackBar(content: Text('The current password is not correct')),
      );
    }
  }

  Future<void> _setBuffer(BuildContext context) async {
    final state = AppScope.of(context);
    final controller = TextEditingController();
    final value = await showDialog<Money>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Minimum cash buffer'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Keep at least',
            prefixText: r'$ ',
          ),
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
                    .pop(Money.parse(controller.text, state.currency));
              } on FormatException {
                return;
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null) return;
    final existing = state.store.entity(
      AppEntityTypes.appPreferences,
      AppEntityTypes.appPreferencesId,
    );
    await state.store.upsertEntity(
      AppEntityTypes.appPreferences,
      AppEntityTypes.appPreferencesId,
      {
        ...?existing?.json,
        'id': AppEntityTypes.appPreferencesId,
        'minimumBufferMinor': value.minor,
      },
    );
    state.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final capabilities = AppScope.servicesOf(context).capabilities;
    final settings = state.settings;
    final buffer =
        state.store
                .entity(AppEntityTypes.appPreferences, AppEntityTypes.appPreferencesId)
                ?.json['minimumBufferMinor']
            as int?;
    final passwordProtected =
        WorkspaceDescriptor.read(
          AppScope.servicesOf(context).workspaceDirectory,
        ).key['protection'] ==
        'password';
    return ListView(
      children: [
        const _Header('Your data'),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: const Text('Import a bank statement (CSV)'),
          onTap: () => _import(context),
        ),
        ListTile(
          leading: const Icon(Icons.rule),
          title: const Text('Categorisation rules'),
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const RulesScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Export transactions (CSV)'),
          subtitle: const Text('For spreadsheets. Not a complete backup.'),
          onTap: () => _exportCsv(context),
        ),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Create an encrypted backup'),
          subtitle: Text(
            settings.syncMode == SyncMode.local
                ? 'Data kept only on this device can be recovered only from a backup.'
                : 'Includes receipts and every entry, with checksums.',
          ),
          onTap: () => _backup(context),
        ),
        if (syncSection != null) ...[const _Header('Sync'), syncSection!],
        const _Header('Planning'),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Minimum cash buffer'),
          subtitle: Text(
            buffer == null
                ? 'Not set'
                : formatMoney(Money(buffer, state.currency)),
          ),
          onTap: () => _setBuffer(context),
        ),
        const _Header('Security'),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: Text(
            passwordProtected
                ? 'Encrypted with your password'
                : 'Encrypted with this device\'s key store',
          ),
          subtitle: passwordProtected
              ? const Text('Tap to change the password')
              : null,
          onTap: passwordProtected ? () => _changePassword(context) : null,
        ),
        const _Header('About this device'),
        ListTile(
          title: const Text('Workspace'),
          subtitle: Text(
            '${settings.currency.code} · ${settings.timezone} · ${settings.locale}',
          ),
        ),
        ListTile(
          title: const Text('Receipt capture'),
          subtitle: Text(
            [
              if (capabilities.documentScanner) 'document scanner',
              if (capabilities.cameraCapture) 'camera',
              'file import',
              if (capabilities.dragAndDrop) 'drag and drop',
              if (capabilities.paste) 'paste',
            ].join(', '),
          ),
        ),
        ListTile(
          title: const Text('Reading receipt text'),
          subtitle: Text(
            capabilities.onDeviceOcr ? 'Available on this device' : 'Not available on this device; receipts are kept and details entered by hand',
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}
