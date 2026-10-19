import 'dart:io';

import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../data/workspace_gate.dart';

/// Restores an encrypted backup on a fresh device. The archive is staged
/// and verified first; nothing becomes active until the user confirms the
/// preview (DATA 03, A16).
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({
    super.key,
    required this.gate,
    required this.needsPassword,
    required this.onRestored,
  });

  final WorkspaceGate gate;
  final bool needsPassword;
  final ValueChanged<FinanceStore> onRestored;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  String? _path;
  final _secret = TextEditingController();
  final _password = TextEditingController();
  StagedRestore? _staged;
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _secret.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _stage() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final staged = await widget.gate.stageBackup(
        File(_path!),
        recoverySecret: _secret.text,
        password: widget.needsPassword ? _password.text : null,
      );
      setState(() => _staged = staged);
    } on BackupDecryptionException {
      setState(() => _error = 'The recovery secret does not open this backup');
    } on Exception catch (e) {
      setState(() => _error = 'The backup could not be read: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staged = _staged;
    final preview = staged?.preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Restore from a backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (staged == null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _path == null ? 'No backup chosen' : _path!.split('/').last,
              ),
              trailing: TextButton(
                onPressed: () async {
                  final path = await AppScope.servicesOf(context).fileImporter
                      .pickBackupPath();
                  if (path != null) setState(() => _path = path);
                },
                child: const Text('Choose backup'),
              ),
            ),
            TextField(
              controller: _secret,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Recovery secret'),
            ),
            if (widget.needsPassword)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText:
                      'New password for this device (10 or more characters)',
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _path == null ? null : _stage,
              child: const Text('Check backup'),
            ),
          ] else ...[
            Text(
              'Backup checked',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _Check(
              'Format and schema are compatible',
              preview!.schemaCompatible,
            ),
            _Check(
              'Every file matches its checksum',
              preview.checksumFailures.isEmpty,
            ),
            _Check(
              'Every journal balances',
              preview.unbalancedJournals.isEmpty,
            ),
            _Check('Record counts match the manifest', preview.countsMatch),
            _Check(
              'All receipt files are present',
              preview.missingAssets.isEmpty,
            ),
            if (preview.unavailableAssets.isNotEmpty)
              Text(
                '${preview.unavailableAssets.length} receipt images were only in the '
                'cloud and are not in this backup.',
              ),
            if (preview.pendingLocalChanges.isNotEmpty)
              Text(
                '${preview.pendingLocalChanges.length} changes had not been synced when '
                'the backup was made; they are included as entries, not replayed.',
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () async {
                    await staged.discard();
                    setState(() => _staged = null);
                  },
                  child: const Text('Discard'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: preview.canActivate
                      ? () async => widget.onRestored(await staged.activate())
                      : null,
                  child: const Text('Use this backup'),
                ),
              ],
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check(this.label, this.ok);
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      ok ? Icons.check_circle_outline : Icons.error_outline,
      color: ok ? null : Theme.of(context).colorScheme.error,
    ),
    title: Text(label),
    subtitle: Text(ok ? 'Passed' : 'Failed'),
  );
}
