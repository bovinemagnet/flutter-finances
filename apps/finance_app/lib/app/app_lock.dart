import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

/// Device authentication (biometrics or the device passcode). It gates the
/// interface only; the data key stays protected by the platform key store
/// (SEC 02).
abstract interface class DeviceAuthenticator {
  Future<bool> isSupported();
  Future<bool> authenticate(String reason);
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason);
    } on Exception {
      return false;
    }
  }
}

/// Hides the app until the user authenticates, on launch and after the app
/// has been in the background longer than [timeout].
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.enabled,
    required this.authenticator,
    required this.child,
    this.timeout = const Duration(minutes: 5),
    this.clock = DateTime.now,
  });

  final bool enabled;
  final DeviceAuthenticator authenticator;
  final Widget child;
  final Duration timeout;
  final DateTime Function() clock;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late var _locked = widget.enabled;
  DateTime? _backgroundedAt;
  var _authenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= widget.clock();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && widget.clock().difference(since) >= widget.timeout) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    _authenticating = true;
    try {
      final ok = await widget.authenticator.authenticate(
        'Unlock your finances',
      );
      if (mounted && ok) setState(() => _locked = false);
    } finally {
      _authenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 16),
            const Text('Your finances are locked'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _unlock, child: const Text('Unlock')),
          ],
        ),
      ),
    );
  }
}
