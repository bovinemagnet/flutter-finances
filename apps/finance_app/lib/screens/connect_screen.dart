import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/sync_controller.dart';
import '../data/workspace_gate.dart';
import 'startup_screen.dart';

/// Sets up a new device from data already synced from another device. The
/// local workspace starts empty, so the server's data downloads without any
/// merge (SYNC 01).
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.gate,
    required this.needsPassword,
    required this.createSync,
    required this.onConnected,
  });

  final WorkspaceGate gate;
  final bool needsPassword;
  final SyncController Function(AppState state) createSync;
  final void Function(AppState state, SyncController sync) onConnected;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _server = TextEditingController();
  final _issuer = TextEditingController();
  final _client = TextEditingController(text: 'finance-app');
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _server.dispose();
    _issuer.dispose();
    _client.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    String? password;
    if (widget.needsPassword) {
      password = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (context) => PasswordScreen(
            title: 'Protect your data on this device',
            explanation:
                'This device has no system key store, so the copy of '
                'your data kept here is encrypted with a password.',
            confirm: true,
            onSubmit: (p) async => Navigator.of(context).pop(p),
          ),
        ),
      );
      if (password == null) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    FinanceStore? store;
    try {
      store = await widget.gate.create(
        password: password,
        timezone: 'Australia/Brisbane',
        locale: 'en_AU',
        syncMode: SyncMode.local,
      );
      final state = AppState(
        store,
        today: () => LocalDate.fromDateTime(DateTime.now()),
      );
      final sync = widget.createSync(state);
      await sync.saveSettings(
        SyncSettings(
          serverUrl: _server.text.trim(),
          issuer: _issuer.text.trim(),
          clientId: _client.text.trim(),
        ),
      );
      await sync.signIn();
      final remotes = await sync.remoteWorkspaces();
      if (remotes.isEmpty) {
        throw StateError('There is no synced workspace for this account yet');
      }
      if (!mounted) return;
      final remote = remotes.length == 1
          ? remotes.single
          : await showDialog<RemoteWorkspace>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Which workspace?'),
                children: [
                  for (final r in remotes)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(r),
                      child: Text(r.name),
                    ),
                ],
              ),
            );
      if (remote == null) throw StateError('No workspace was chosen');
      if (remote.currencyCode != state.currency.code) {
        throw StateError(
          'That workspace uses ${remote.currencyCode}, which this '
          'version does not support',
        );
      }
      await sync.enable(await sync.prepare(existing: remote));
      widget.onConnected(state, sync);
    } on Exception catch (e) {
      await _discard(store);
      setState(() => _error = 'Could not connect: $e');
    } on StateError catch (e) {
      await _discard(store);
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removes the empty local workspace so first-time setup can run again.
  Future<void> _discard(FinanceStore? store) async {
    if (store == null) return;
    await store.close();
    if (await widget.gate.directory.exists()) {
      await widget.gate.directory.delete(recursive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Use my synced data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Connect this device to the finances you already sync from '
            'another device. You will sign in through your browser.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _server,
            decoration: const InputDecoration(labelText: 'Service address'),
          ),
          TextField(
            controller: _issuer,
            decoration: const InputDecoration(
              labelText: 'Sign-in provider address',
            ),
          ),
          TextField(
            controller: _client,
            decoration: const InputDecoration(
              labelText: 'Application identifier',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: const Text('Sign in and connect'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
