import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_lock.dart';
import 'app/app_scope.dart';
import 'app/theme.dart';
import 'background_sync.dart';
import 'data/app_state.dart';
import 'data/oidc.dart';
import 'data/sync_controller.dart';
import 'features/sync/sync_section.dart';
import 'platform/adapters/background.dart';
import 'platform/adapters/browser_sign_in.dart';
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
  SyncController? _sync;

  SyncController _createSync(AppState state) {
    final capabilities = widget.services.capabilities;
    return SyncController(
      state,
      tokens: SecureTokenStore(PlatformSecureKeyStore()),
      settingsStore: FileSyncSettingsStore(
        File(
          '${widget.services.workspaceDirectory.parent.path}/sync-settings.json',
        ),
      ),
      redirectUri: redirectUriFor(capabilities),
      browserSignIn: (session) => signInWithBrowser(session, capabilities),
      platform: Platform.operatingSystem,
      deviceName: Platform.localHostname,
    );
  }

  Future<void> _ready(AppState state, {SyncController? sync}) async {
    final capabilities = widget.services.capabilities;
    sync ??= _createSync(state);
    setState(() {
      _state = state;
      _sync = sync;
    });
    await sync.start();
    if (capabilities.backgroundWork && sync.isSynced) {
      await WorkmanagerScheduler(backgroundSyncDispatcher)
          .schedulePeriodicSync(const Duration(hours: 1))
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    _sync?.dispose();
    super.dispose();
  }

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
              onReady: _ready,
              createSync: _createSync,
            )
          : AppLockGate(
              enabled: _state!.appLockEnabled,
              authenticator: widget.services.authenticator,
              child: HomeScreen(syncSection: SyncSection(controller: _sync!)),
            ),
    );
    return AppScope(
      state: _state,
      services: widget.services,
      sync: _sync,
      child: app,
    );
  }
}
