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
    this.longPollWait = const Duration(seconds: 25),
    this.waitRetryDelay = const Duration(seconds: 5),
    this.maxWaitRetryDelay = const Duration(minutes: 2),
    this.pushDelay = const Duration(seconds: 1),
    this.retry = const RetryPolicy(),
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

  /// How long each waiting request asks the server to hold it open.
  final Duration longPollWait;

  /// First pause after a failed wait; doubles up to [maxWaitRetryDelay].
  final Duration waitRetryDelay;
  final Duration maxWaitRetryDelay;

  /// How long after a save the change is sent, so a burst is one sync.
  final Duration pushDelay;

  /// Transport retry policy; tests shorten it.
  final RetryPolicy retry;

  /// Replaces the browser session, for tests and service accounts.
  final AccessTokenProvider? accessToken;

  SyncPhase phase = SyncPhase.off;
  String? lastError;
  DateTime? lastSyncedAt;
  SyncReport? lastReport;
  OidcSession? _session;
  SyncClient? _client;
  Timer? _timer;

  // Waiting loop state. A stopped loop notices the changed generation when
  // its request returns and does nothing further.
  int _waitGeneration = 0;
  bool _waiting = false;
  bool _waitingAllowed = false;
  bool _longPollUnsupported = false;

  // Push-after-save state.
  bool _listening = false;
  int _lastSavedMark = 0;
  Timer? _pushTimer;
  bool _syncQueued = false;

  /// Whether a waiting request loop is running (NFR 05).
  bool get isWaiting => _waiting;

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
    retry: retry,
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
      _waitingAllowed = true;
      _listenForSaves();
      unawaited(syncNow());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _stopWaiting();
    _stopListeningForSaves();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground launch reliably resumes queued work.
    if (state == AppLifecycleState.resumed && isSynced) {
      if (phase != SyncPhase.off) {
        _waitingAllowed = true;
        _startWaiting();
      }
      unawaited(syncNow());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _stopWaiting();
    }
  }

  void _listenForSaves() {
    if (_listening) return;
    _listening = true;
    _lastSavedMark = state.savedCommandMark;
    state.addListener(_onStateChanged);
  }

  void _stopListeningForSaves() {
    if (_listening) state.removeListener(_onStateChanged);
    _listening = false;
    _pushTimer?.cancel();
    _pushTimer = null;
    _syncQueued = false;
  }

  /// Only a newly queued command is a save. The mark never falls, so a sync
  /// that empties the outbox neither hides a save made during it nor starts
  /// another push.
  void _onStateChanged() {
    final mark = state.savedCommandMark;
    final saved = mark > _lastSavedMark;
    _lastSavedMark = mark;
    if (saved) {
      _pushTimer?.cancel();
      _pushTimer = Timer(pushDelay, _syncAfterSave);
    }
  }

  /// Sends the outbox first and receipt files afterwards, so the change
  /// reaches the other device before any large upload. Failures stay in the
  /// outbox for the next sync.
  Future<void> _syncAfterSave() async {
    if (!_listening || !isSynced) return;
    if (phase == SyncPhase.syncing) {
      _syncQueued = true;
      return;
    }
    await syncNow(uploadAssets: false);
    if (phase == SyncPhase.failed || !_listening) return;
    try {
      await client.uploadAssets();
    } on Exception {
      // Left for the next sync.
    }
  }

  void _startWaiting() {
    if (!_waitingAllowed || _waiting || _longPollUnsupported || !isSynced) {
      return;
    }
    _waiting = true;
    unawaited(_waitLoop(++_waitGeneration));
  }

  void _stopWaiting() {
    _waitingAllowed = false;
    _waiting = false;
    _waitGeneration++;
  }

  /// Keeps one waiting request open so another device's change arrives
  /// promptly, falling back to the periodic sync whenever it cannot.
  Future<void> _waitLoop(int generation) async {
    var delay = waitRetryDelay;
    bool current() => generation == _waitGeneration;
    // Ends this loop only when it is still the current one.
    void finish() {
      if (current()) _waiting = false;
    }

    while (current()) {
      var backOff = false;
      try {
        final result = await client.waitForChanges(wait: longPollWait);
        if (!current()) return;
        if (!result.supported) {
          _longPollUnsupported = true;
          finish();
          return;
        }
        if (result.needsPull) {
          final alreadySyncing = phase == SyncPhase.syncing;
          await syncNow();
          if (!current()) return;
          // A failed or skipped sync would otherwise make this spin.
          backOff = alreadySyncing || phase == SyncPhase.failed;
        } else if (result.changes > 0) {
          state.refresh();
          notifyListeners();
        }
        if (!backOff) delay = waitRetryDelay;
      } on AuthenticationRequiredException {
        if (!current()) return;
        lastError = 'Sign in again to continue syncing';
        phase = SyncPhase.failed;
        finish();
        notifyListeners();
        return;
      } on Exception {
        if (!current()) return;
        backOff = true;
      } on Error {
        // A stopped loop may return after the store has been closed.
        if (!current()) return;
        finish();
        rethrow;
      }
      if (backOff) {
        await Future<void>.delayed(delay);
        final doubled = delay * 2;
        delay = doubled > maxWaitRetryDelay ? maxWaitRetryDelay : doubled;
      }
    }
  }

  Future<void> signIn() async {
    await browserSignIn(session);
    notifyListeners();
  }

  Future<List<RemoteWorkspace>> remoteWorkspaces() =>
      client.listRemoteWorkspaces();

  /// Household members and invitations for the synced workspace.
  HouseholdClient get household => HouseholdClient.of(client);

  String get workspaceId => state.settings.workspaceId;

  /// Bank feed connections and their proposals (P1).
  BankFeedClient get bankFeeds => BankFeedClient.of(client);

  /// Consent to, and results of, optional cloud extraction (P1).
  ExtractionClient get extraction => ExtractionClient.of(client);

  /// Joins a household from an invitation code before connecting.
  Future<HouseholdRole> acceptInvitation(String code) =>
      household.accept(InvitationCode.parse(code));

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
    _waitingAllowed = true;
    _listenForSaves();
    await syncNow();
  }

  Future<void> syncNow({
    bool meteredConnection = false,
    bool uploadAssets = true,
  }) async {
    if (!isSynced || phase == SyncPhase.syncing) return;
    phase = SyncPhase.syncing;
    notifyListeners();
    try {
      lastReport = await client.sync(
        meteredConnection: meteredConnection,
        uploadAssets: uploadAssets,
      );
      lastSyncedAt = DateTime.now();
      lastError = null;
      phase = SyncPhase.idle;
      _startWaiting();
    } on AuthenticationRequiredException {
      lastError = 'Sign in again to continue syncing';
      phase = SyncPhase.failed;
    } on SyncUpdateRequiredException {
      lastError =
          'Update the app or the sync service to keep syncing. '
          'Your changes are kept on this device.';
      phase = SyncPhase.failed;
    } on Exception catch (e) {
      // Changes stay safely in the outbox and are retried later.
      lastError = 'Sync paused: $e';
      phase = SyncPhase.failed;
    }
    state.refresh();
    notifyListeners();
    if (_syncQueued) {
      _syncQueued = false;
      unawaited(_syncAfterSave());
    }
  }

  Future<void> signOut() async {
    _timer?.cancel();
    _timer = null;
    _stopWaiting();
    _stopListeningForSaves();
    await session.signOut();
    phase = SyncPhase.off;
    notifyListeners();
  }
}
