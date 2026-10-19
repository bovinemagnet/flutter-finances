import 'dart:io';

import 'package:finance_store/finance_store.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import 'data/oidc.dart';
import 'data/platform_key_store.dart';
import 'data/sync_controller.dart';

/// Opportunistic mobile background sync (UX 04). It only runs for a
/// workspace protected by the platform key store, since nobody is present to
/// type a password; foreground launch always resumes queued work anyway.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/workspace');
    final keyStore = PlatformSecureKeyStore();
    try {
      if (WorkspaceDescriptor.read(directory).key['protection'] != 'platform') {
        return true;
      }
    } on WorkspaceNotFoundException {
      return true;
    }
    final store = await FinanceStore.open(
      directory,
      keyProtection: KeyProtection.platform(keyStore),
    );
    try {
      if (store.settings.syncMode != SyncMode.synced) return true;
      final settings = FileSyncSettingsStore(
        File('${support.path}/sync-settings.json'),
      ).read();
      if (!settings.isComplete) return true;
      final httpClient = http.Client();
      final session = OidcSession(
        OidcConfig(
          issuer: settings.issuer,
          clientId: settings.clientId,
          redirectUri: '',
        ),
        tokens: SecureTokenStore(keyStore),
        httpClient: httpClient,
      );
      if (!await session.isSignedIn) return true;
      await SyncClient(
        store,
        httpClient: httpClient,
        baseUri: Uri.parse(settings.serverUrl),
        accessToken: session.accessToken,
      ).sync(meteredConnection: true);
      return true;
    } on Exception {
      // Retried at the next opportunity or when the app is opened.
      return false;
    } finally {
      await store.close();
    }
  });
}
