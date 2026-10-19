import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/workspace_gate.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/onboarding/onboarding_model.dart';

/// Opens the local workspace, or runs first-time setup when there is none.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.gate, required this.onReady});

  final WorkspaceGate gate;
  final ValueChanged<AppState> onReady;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

enum _Phase { checking, onboarding, unlocking, failed }

class _StartupScreenState extends State<StartupScreen> {
  var _phase = _Phase.checking;
  var _needsPassword = false;
  String? _error;

  LocalDate _today() => LocalDate.fromDateTime(DateTime.now());

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    switch (widget.gate.inspect()) {
      case WorkspaceStatus.none:
        final needsPassword = await widget.gate.newWorkspaceNeedsPassword();
        setState(() {
          _needsPassword = needsPassword;
          _phase = _Phase.onboarding;
        });
      case WorkspaceStatus.locked:
        setState(() => _phase = _Phase.unlocking);
      case WorkspaceStatus.platformProtected:
        try {
          widget.onReady(AppState(await widget.gate.open(), today: _today));
        } on Exception catch (e) {
          setState(() {
            _phase = _Phase.failed;
            _error =
                'The key for this workspace is unavailable ($e). '
                'Restore from a backup to continue.';
          });
        }
    }
  }

  Future<void> _finishOnboarding(
    OnboardingResult result,
    String? password,
  ) async {
    final store = await widget.gate.create(
      password: password,
      timezone: result.timezone,
      locale: result.locale,
      syncMode: result.syncMode,
    );
    final state = AppState(store, today: _today);
    await state.applyOnboarding(result);
    widget.onReady(state);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Phase.failed:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error ?? 'Unable to open your data'),
            ),
          ),
        );
      case _Phase.unlocking:
        return PasswordScreen(
          title: 'Unlock your finances',
          confirm: false,
          onSubmit: (password) async {
            final store = await widget.gate.open(password: password);
            widget.onReady(AppState(store, today: _today));
          },
        );
      case _Phase.onboarding:
        return OnboardingFlow(
          model: OnboardingModel(today: _today()),
          onFinish: (result) async {
            String? password;
            if (_needsPassword) {
              password = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (context) => PasswordScreen(
                    title: 'Protect your data',
                    explanation:
                        'This device has no system key store, so your '
                        'data is encrypted with a password. It cannot be '
                        'recovered if you forget it, except from a backup.',
                    confirm: true,
                    onSubmit: (p) async => Navigator.of(context).pop(p),
                  ),
                ),
              );
              if (password == null) return;
            }
            await _finishOnboarding(result, password);
          },
        );
    }
  }
}

/// Password entry used for unlocking or for creating a password-protected
/// workspace.
class PasswordScreen extends StatefulWidget {
  const PasswordScreen({
    super.key,
    required this.title,
    required this.onSubmit,
    required this.confirm,
    this.explanation,
  });

  final String title;
  final String? explanation;
  final bool confirm;
  final Future<void> Function(String password) onSubmit;

  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.confirm) {
      if (_password.text.length < 10) {
        setState(() => _error = 'Use at least 10 characters');
        return;
      }
      if (_password.text != _repeat.text) {
        setState(() => _error = 'The passwords do not match');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_password.text);
    } on WrongPasswordException {
      setState(() => _error = 'That password is not correct');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              if (widget.explanation != null) Text(widget.explanation!),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => widget.confirm ? null : _submit(),
              ),
              if (widget.confirm) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _repeat,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Repeat password',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.confirm ? 'Continue' : 'Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
