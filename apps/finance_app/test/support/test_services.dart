import 'dart:io';

import 'package:finance_app/app/app_lock.dart';
import 'package:finance_app/app/app_scope.dart';
import 'package:finance_app/platform/capabilities.dart';
import 'package:finance_app/platform/services.dart';
import 'package:finance_app/platform/text_recognition.dart';
import 'package:flutter/foundation.dart';

/// Device services with no hardware, for widget tests.
AppServices testServices() => AppServices(
  capabilities: PlatformCapabilities.forPlatform(TargetPlatform.android),
  scanner: NoScanner(),
  fileImporter: NoFiles(),
  shareInbox: NoShares(),
  notifications: NoNotifications(),
  textRecogniser: UnavailableTextRecogniser(),
  workspaceDirectory: Directory.systemTemp,
  authenticator: NoAuth(),
);

class NoFiles implements FileImporter {
  @override
  Future<List<CapturedFile>> pickReceipts() async => const [];
  @override
  Future<CapturedFile?> pickStatement() async => null;
  @override
  Future<String?> pickBackupPath() async => null;
  @override
  Future<String?> chooseDirectory() async => null;
  @override
  Future<String?> chooseSaveLocation(String suggestedName) async => null;
}

class NoScanner implements ReceiptScanner {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<List<CapturedFile>> capture() async => const [];
}

class NoNotifications implements Notifications {
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> cancelAll() async {}
  @override
  Future<void> initialise() async {}
  @override
  Future<void> schedule(Reminder reminder, {required bool showDetails}) async {}
}

class NoShares implements ShareInbox {
  @override
  Stream<List<CapturedFile>> get incoming => const Stream.empty();
  @override
  Future<List<CapturedFile>> takePending() async => const [];
}

class NoAuth implements DeviceAuthenticator {
  @override
  Future<bool> isSupported() async => false;
  @override
  Future<bool> authenticate(String reason) async => true;
}
