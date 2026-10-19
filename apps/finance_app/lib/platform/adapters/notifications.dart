import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../services.dart';

/// Local reminders. Delivery is best effort because the operating system
/// controls it; the in-app calendar remains the authoritative record.
class LocalNotifications implements Notifications {
  LocalNotifications({this.timezone = 'Australia/Brisbane'});

  final String timezone;
  final _plugin = FlutterLocalNotificationsPlugin();
  var _ready = false;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'bills',
      'Bills and reminders',
      channelDescription: 'Upcoming bills and planning reminders',
      visibility: NotificationVisibility.private,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
  );

  @override
  Future<void> initialise() async {
    if (_ready) return;
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(timezone));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
        ),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'Finances',
          appUserModelId: 'com.paulsnow.finance.app',
          guid: '6f0a5d1e-6a43-4f43-9a52-0e4f5d6a8c11',
        ),
      ),
    );
    _ready = true;
  }

  @override
  Future<void> schedule(Reminder reminder, {required bool showDetails}) async {
    await initialise();
    await _plugin.zonedSchedule(
      id: reminder.id,
      scheduledDate: tz.TZDateTime.from(reminder.at, tz.local),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: reminder.title,
      body: showDetails ? reminder.detailedBody : reminder.privateBody,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}
