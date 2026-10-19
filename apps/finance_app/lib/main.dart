import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_lock.dart';
import 'app/app_scope.dart';
import 'app/theme.dart';
import 'data/app_state.dart';
import 'data/platform_key_store.dart';
import 'data/workspace_gate.dart';
import 'platform/adapters/file_importer.dart';
import 'platform/adapters/notifications.dart';
import 'platform/adapters/scanners.dart';
import 'platform/adapters/share_inbox.dart';
import 'platform/capabilities.dart';
import 'platform/services.dart';
import 'platform/text_recognition.dart';
import 'screens/home_screen.dart';
import 'screens/startup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_AU');
  final capabilities = await PlatformCapabilities.detect();
  final support = await getApplicationSupportDirectory();
  final workspace = Directory('${support.path}/workspace');
  final services = AppServices(
    capabilities: capabilities,
    scanner: FallbackReceiptScanner(
      NativeDocumentScanner(capabilities),
      BasicCameraScanner(
        capabilities,
        fromLibrary: !capabilities.cameraCapture,
      ),
    ),
    fileImporter: PlatformFileImporter(),
    shareInbox: capabilities.shareTarget
        ? PluginShareInbox()
        : EmptyShareInbox(),
    notifications: LocalNotifications(),
    textRecogniser: !capabilities.onDeviceOcr
        ? UnavailableTextRecogniser()
        : capabilities.isDesktop
        ? TesseractTextRecogniser()
        : MlKitTextRecogniser(),
    workspaceDirectory: workspace,
    authenticator: LocalDeviceAuthenticator(),
  );
  runApp(
    FinanceApp(
      services: services,
      gate: WorkspaceGate(workspace, PlatformSecureKeyStore()),
    ),
  );
}

class FinanceApp extends StatefulWidget {
  const FinanceApp({super.key, required this.services, required this.gate});

  final AppServices services;
  final WorkspaceGate gate;

  @override
  State<FinanceApp> createState() => _FinanceAppState();
}

class _FinanceAppState extends State<FinanceApp> {
  AppState? _state;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'Finances',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      highContrastTheme: buildTheme(Brightness.light, highContrast: true),
      highContrastDarkTheme: buildTheme(Brightness.dark, highContrast: true),
      locale: const Locale('en', 'AU'),
      supportedLocales: const [
        Locale('en', 'AU'),
        Locale('en', 'GB'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _state == null
          ? StartupScreen(
              gate: widget.gate,
              onReady: (state) => setState(() => _state = state),
            )
          : AppLockGate(
              enabled: _state!.appLockEnabled,
              authenticator: widget.services.authenticator,
              child: const HomeScreen(),
            ),
    );
    return AppScope(state: _state, services: widget.services, child: app);
  }
}
