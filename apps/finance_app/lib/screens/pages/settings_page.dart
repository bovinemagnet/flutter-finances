import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../../platform/services.dart';
import '../../app/app_scope.dart';
import '../../app/appearance.dart';
import '../../features/imports/import_screen.dart';
import '../../data/year_pack.dart';
import '../../features/settings/rules_screen.dart';
import '../../features/settings/tags_screen.dart';
import '../../format/formatters.dart';
import 'reports_page.dart';

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
    try {
      final outcome = await services.fileExporter.exportFile(
        'finances-${state.today()}.fsbackup',
        (file) => exportBackup(state.store, file, recoverySecret: secret),
      );
      if (outcome == ExportOutcome.cancelled) return;
      await state.recordBackup();
      messenger.showSnackBar(
        const SnackBar(content: Text('Encrypted backup saved')),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _exportCsv(BuildContext context) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final filter = await showDialog<TransactionExportFilter>(
      context: context,
      builder: (_) =>
          _TransactionExportDialog(chart: state.chart, today: state.today()),
    );
    if (filter == null) return;
    try {
      final outcome = await services.fileExporter.exportFile(
        filter.from == null
            ? 'transactions-${state.today()}.csv'
            : 'transactions-${filter.from}-to-${filter.to}.csv',
        (file) => file.writeAsString(
          exportTransactionsCsv(
            state.ledger.journals,
            state.chart,
            filter: filter,
          ),
        ),
      );
      if (outcome == ExportOutcome.cancelled) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Transactions exported')),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _exportReceipts(BuildContext context) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    var count = 0;
    try {
      final outcome = await services.fileExporter.exportFolder(
        'receipts-${state.today()}',
        (folder) async => count = await state.receipts.exportOriginals(folder),
      );
      if (outcome == ExportOutcome.cancelled) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported $count receipt files with a manifest'),
        ),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _exportYearPack(BuildContext context) async {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final year = await showDialog<DateRange>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Which financial year?'),
        children: [
          for (final year in state.financialYears)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(year),
              child: Text(year.label),
            ),
        ],
      ),
    );
    if (year == null) return;
    YearPackResult? result;
    try {
      final outcome = await services.fileExporter.exportFolder(
        yearPackName(year),
        (folder) async => result = await writeYearPack(state, folder, year),
      );
      if (outcome == ExportOutcome.cancelled) return;
      final missing = result!.onServerOnly;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Saved the ${year.label} pack with ${result!.receiptFiles} receipt '
            'files.${missing == 0 ? '' : ' $missing more are not on this '
                      'device, so are listed but not included.'}',
          ),
        ),
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _freeSpace(BuildContext context, int bytes) async {
    final state = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await state.store.vault.evictToFree(bytes);
    state.refresh();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Removed ${result.evictedCount} copies already safe on the server '
          '(${_size(result.freedBytes)}). They download again when opened.',
        ),
      ),
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

  /// Asks for the minimum cash buffer and saves it.
  static Future<void> editMinimumBuffer(BuildContext context) async {
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
    if (value != null) await state.setMinimumBuffer(value);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final services = AppScope.servicesOf(context);
    final capabilities = services.capabilities;
    final settings = state.settings;
    final buffer = state.minimumBuffer;
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
          leading: const Icon(Icons.sell_outlined),
          title: const Text('Tags'),
          subtitle: const Text('Rename or merge the tags on your entries'),
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const TagsScreen())),
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
        ListTile(
          leading: const Icon(Icons.event_note_outlined),
          title: const Text('Financial year pack'),
          subtitle: const Text(
            'Transactions, totals and receipts for one July to June year. '
            'A record, not tax advice.',
          ),
          onTap: () => _exportYearPack(context),
        ),
        ListTile(
          leading: const Icon(Icons.folder_zip_outlined),
          title: const Text('Export receipts'),
          subtitle: const Text('Original files with a manifest'),
          onTap: () => _exportReceipts(context),
        ),
        const _Header('Storage on this device'),
        Builder(
          builder: (context) {
            final report = state.store.vault.storageReport();
            return Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: Text('${_size(report.totalBytes)} used'),
                  subtitle: Text(
                    'Receipts ${_size(report.originalBytes)}, readable copies '
                    '${_size(report.derivativeBytes)}, previews ${_size(report.previewBytes)}, '
                    'database ${_size(report.databaseBytes)}. '
                    '${_size(report.unsyncedBytes)} is not yet backed up to the server '
                    'and is never removed.',
                  ),
                ),
                if (report.evictableBytes > 0)
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: Text('Free ${_size(report.evictableBytes)}'),
                    subtitle: const Text(
                      'Removes local copies of receipts already stored on the server',
                    ),
                    onTap: () => _freeSpace(context, report.evictableBytes),
                  ),
              ],
            );
          },
        ),
        if (syncSection != null) ...[const _Header('Sync'), syncSection!],
        if (AppScope.appearanceOf(context) case final appearance?) ...[
          const _Header('Display'),
          AppearanceTile(appearance: appearance),
        ],
        const _Header('Planning'),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Minimum cash buffer'),
          subtitle: Text(buffer == null ? 'Not set' : formatMoney(buffer)),
          onTap: () => editMinimumBuffer(context),
        ),
        ListTile(
          leading: const Icon(Icons.calendar_month_outlined),
          title: const Text('Receipt dates like 03/04'),
          trailing: DropdownButton<DateConvention>(
            value: state.dateConvention,
            items: const [
              DropdownMenuItem(
                value: DateConvention.dayMonth,
                child: Text('3 April'),
              ),
              DropdownMenuItem(
                value: DateConvention.monthDay,
                child: Text('4 March'),
              ),
            ],
            onChanged: (v) => v == null ? null : state.setDateConvention(v),
          ),
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
        FutureBuilder<bool>(
          future: AppScope.servicesOf(context).authenticator.isSupported(),
          builder: (context, snapshot) => snapshot.data == true
              ? SwitchListTile(
                  secondary: const Icon(Icons.fingerprint),
                  title: const Text('Lock the app'),
                  subtitle: const Text(
                    'Ask for your fingerprint, face or device passcode '
                    'when opening the app and after five minutes away',
                  ),
                  value: state.appLockEnabled,
                  onChanged: state.setAppLock,
                )
              : const SizedBox.shrink(),
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
            capabilities.onDeviceOcr
                ? 'Available on this device'
                : '${services.textRecogniser.unavailableMessage}; '
                      'receipts are kept and details entered by hand',
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

String _size(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes bytes';
}

/// Chooses which entries go in a transaction export (EXP 01).
class _TransactionExportDialog extends StatefulWidget {
  const _TransactionExportDialog({required this.chart, required this.today});

  final Chart chart;
  final LocalDate today;

  @override
  State<_TransactionExportDialog> createState() =>
      _TransactionExportDialogState();
}

class _TransactionExportDialogState extends State<_TransactionExportDialog> {
  RangeChoice? _period;
  String? _accountId;
  var _includePending = false;

  TransactionExportFilter get _filter {
    final range = _period?.dateRange(widget.today);
    return TransactionExportFilter(
      from: range?.start,
      to: range?.end,
      accountIds: {?_accountId},
      includePending: _includePending,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Export transactions'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<RangeChoice?>(
            isExpanded: true,
            initialValue: _period,
            decoration: const InputDecoration(labelText: 'Period'),
            items: [
              const DropdownMenuItem(child: Text('All time')),
              for (final r in RangeChoice.values)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
            onChanged: (r) => setState(() => _period = r),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [
              const DropdownMenuItem(child: Text('All accounts')),
              for (final a in widget.chart.accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (id) => setState(() => _accountId = id),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include pending entries'),
            value: _includePending,
            onChanged: (v) => setState(() => _includePending = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_filter),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
