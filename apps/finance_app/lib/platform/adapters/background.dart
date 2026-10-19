import 'package:workmanager/workmanager.dart';

import '../services.dart';

const syncTaskName = 'finance.sync';

/// Mobile background synchronisation through the operating system scheduler.
class WorkmanagerScheduler implements BackgroundScheduler {
  WorkmanagerScheduler(this.callbackDispatcher);

  /// A top-level function annotated with `@pragma('vm:entry-point')`.
  final Function callbackDispatcher;
  var _initialised = false;

  Future<void> _init() async {
    if (_initialised) return;
    await Workmanager().initialize(callbackDispatcher);
    _initialised = true;
  }

  @override
  Future<void> schedulePeriodicSync(Duration frequency) async {
    await _init();
    await Workmanager().registerPeriodicTask(
      syncTaskName,
      syncTaskName,
      frequency: frequency,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  @override
  Future<void> cancelAll() => Workmanager().cancelAll();
}

/// Desktop: no background work; queued work resumes on launch and while the
/// window is open.
class ForegroundOnlyScheduler implements BackgroundScheduler {
  @override
  Future<void> schedulePeriodicSync(Duration frequency) async {}

  @override
  Future<void> cancelAll() async {}
}
