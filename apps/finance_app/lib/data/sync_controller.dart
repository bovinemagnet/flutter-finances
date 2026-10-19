import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:finance_store/finance_store.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'app_state.dart';
import 'oidc.dart';

/// Server and identity provider addresses for synced mode.
class SyncSettings {
  const SyncSettings({
    required this.serverUrl,
    required this.issuer,
    required this.clientId,
  });

  factory SyncSettings.fromJson(Map<String, Object?> json) => SyncSettings(
    serverUrl: json['serverUrl'] as String? ?? '',
    issuer: json['issuer'] as String? ?? '',
    clientId: json['clientId'] as String? ?? 'finance-app',
  );

  final String serverUrl;
  final String issuer;
  final String clientId;

  bool get isComplete =>
      serverUrl.isNotEmpty && issuer.isNotEmpty && clientId.isNotEmpty;

  Map<String, Object?> toJson() => {
    'serverUrl': serverUrl,
    'issuer': issuer,
    'clientId': clientId,
  };
}

/// Where this device keeps its sync settings. They are device configuration,
/// not finance data, so they are never synced: a fresh device that only
/// knows the server address still counts as empty when it connects.
abstract interface class SyncSettingsStore {
  SyncSettings read();
  Future<void> write(SyncSettings settings);
}

class FileSyncSettingsStore implements SyncSettingsStore {
  FileSyncSettingsStore(this.file);
  final File file;

  @override
  SyncSettings read() {
    try {
      return SyncSettings.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    } on Exception {
      return SyncSettings.fromJson(const {});
    }
  }

  @override
  Future<void> write(SyncSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}

class MemorySyncSettingsStore implements SyncSettingsStore {
  SyncSettings _value = SyncSettings.fromJson(const {});
  @override
  SyncSettings read() => _value;
  @override
  Future<void> write(SyncSettings settings) async => _value = settings;
}

enum SyncPhase { off, idle, syncing, failed }

/// Optional personal sync (section 12): signs in through the system browser,
/// connects this workspace to a server workspace after an explicit preview,
/// and syncs on demand, on return to the foreground and periodically while
/// the app is open. Background work is opportunistic (UX 04).
class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController(
    this.state, {
    required this.tokens,
    required this.settingsStore,
    required this.redirectUri,
    required this.browserSignIn,
    this.platform = 'unknown',
    this.deviceName = 'This device',
    http.Client? httpClient,
    this.interval = const Duration(minutes: 2),
    this.accessToken,
  }) : _http = httpClient ?? http.Client();

  final AppState state;
  final TokenStore tokens;
  final SyncSettingsStore settingsStore;
  final String redirectUri;
  final Future<void> Function(OidcSession session) browserSignIn;
  final String platform;
  final String deviceName;
  final http.Client _http;
  final Duration interval;

  /// Replaces the browser session, for tests and service accounts.
  final AccessTokenProvider? accessToken;

  SyncPhase phase = SyncPhase.off;
  String? lastError;
  DateTime? lastSyncedAt;
  SyncReport? lastReport;
  OidcSession? _session;
  SyncClient? _client;
  Timer? _timer;

  SyncSettings get settings => settingsStore.read();

  bool get isSynced => state.settings.syncMode == SyncMode.synced;

  Future<void> saveSettings(SyncSettings value) async {
    await settingsStore.write(value);
    _session = null;
    _client = null;
    notifyListeners();
  }

  OidcSession get session => _session ??= OidcSession(
    OidcConfig(
      issuer: settings.issuer,
      clientId: settings.clientId,
      redirectUri: redirectUri,
    ),
    tokens: tokens,
    httpClient: _http,
  );

  SyncClient get client => _client ??= SyncClient(
    state.store,
    httpClient: _http,
    baseUri: Uri.parse(settings.serverUrl),
    accessToken: accessToken ?? session.accessToken,
  );

  Future<bool> get isSignedIn async =>
      accessToken != null || await session.isSignedIn;

  /// Starts foreground sync for an already synced workspace.
  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    if (isSynced && settings.isComplete && await isSignedIn) {
      phase = SyncPhase.idle;
      _timer = Timer.periodic(interval, (_) => syncNow());
      unawaited(syncNow());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground launch reliably resumes queued work.
    if (state == AppLifecycleState.resumed && isSynced) {
      unawaited(syncNow());
    }
  }

  Future<void> signIn() async {
    await browserSignIn(session);
    notifyListeners();
  }

  Future<List<RemoteWorkspace>> remoteWorkspaces() =>
      client.listRemoteWorkspaces();

  /// Creates a server workspace for this device's data, or uses [existing],
  /// registers this device and returns the preview the user must confirm.
  Future<SyncBootstrapPreview> prepare({
    RemoteWorkspace? existing,
    String? name,
  }) async {
    final remote =
        existing ??
        await client.createRemoteWorkspace(name: name ?? 'My finances');
    await client.registerDevice(
      workspaceId: remote.id,
      name: deviceName,
      platform: platform,
    );
    return client.previewBootstrap(remoteWorkspaceId: remote.id);
  }

  Future<void> enable(SyncBootstrapPreview preview) async {
    await client.enableSync(preview);
    state.refresh();
    phase = SyncPhase.idle;
    _timer ??= Timer.periodic(interval, (_) => syncNow());
    await syncNow();
  }

  Future<void> syncNow({bool meteredConnection = false}) async {
    if (!isSynced || phase == SyncPhase.syncing) return;
    phase = SyncPhase.syncing;
    notifyListeners();
    try {
      lastReport = await client.sync(meteredConnection: meteredConnection);
      lastSyncedAt = DateTime.now();
      lastError = null;
      phase = SyncPhase.idle;
    } on AuthenticationRequiredException {
      lastError = 'Sign in again to continue syncing';
      phase = SyncPhase.failed;
    } on Exception catch (e) {
      // Changes stay safely in the outbox and are retried later.
      lastError = 'Sync paused: $e';
      phase = SyncPhase.failed;
    }
    state.refresh();
    notifyListeners();
  }

  Future<void> signOut() async {
    _timer?.cancel();
    _timer = null;
    await session.signOut();
    phase = SyncPhase.off;
    notifyListeners();
  }
}
