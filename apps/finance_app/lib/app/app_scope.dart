import 'dart:io';

import 'package:flutter/widgets.dart';

import '../data/app_state.dart';
import '../platform/capabilities.dart';
import 'app_lock.dart';
import '../platform/services.dart';
import '../platform/text_recognition.dart';

/// Device services handed to screens; finance code never checks the OS.
class AppServices {
  const AppServices({
    required this.capabilities,
    required this.scanner,
    required this.fileImporter,
    required this.shareInbox,
    required this.notifications,
    required this.textRecogniser,
    required this.workspaceDirectory,
    required this.authenticator,
  });

  final PlatformCapabilities capabilities;
  final ReceiptScanner scanner;
  final FileImporter fileImporter;
  final ShareInbox shareInbox;
  final Notifications notifications;
  final TextRecogniser textRecogniser;
  final Directory workspaceDirectory;
  final DeviceAuthenticator authenticator;
}

/// Makes [AppState] and [AppServices] available below the root, rebuilding
/// dependants when the state changes. The state is null until a workspace
/// is open; only the startup screens run before that.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({
    super.key,
    required AppState? state,
    required this.services,
    required super.child,
  }) : super(notifier: state);

  final AppServices services;

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppServices servicesOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.services;
}
