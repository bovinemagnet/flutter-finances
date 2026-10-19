import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../support/memory_key_store.dart';
import '../../support/store_fixtures.dart';

/// The server under test, from `FINANCE_E2E_BASE_URL` (set by
/// `tool/e2e/run.sh`); null skips every end-to-end test.
final String? baseUrl = Platform.environment['FINANCE_E2E_BASE_URL'];

/// A test that runs only against a real server.
void e2eTest(String description, Future<void> Function() body) =>
    test(description, () async {
      if (baseUrl == null) {
        markTestSkipped('FINANCE_E2E_BASE_URL is not set');
        return;
      }
      await body();
    });

RSAPrivateKey? _key;

/// An RS256 access token for [subject], signed with the test-only key in
/// `tool/e2e/keys` that the server's `e2e` profile trusts.
String accessToken(String subject) {
  _key ??= RSAPrivateKey(
    File(
      Platform.environment['FINANCE_E2E_PRIVATE_KEY'] ??
          '../../tool/e2e/keys/test-only-private.pem',
    ).readAsStringSync(),
  );
  return JWT({'sub': subject}, issuer: 'https://finance-e2e.invalid/').sign(
    _key!,
    algorithm: JWTAlgorithm.RS256,
    expiresIn: const Duration(hours: 1),
  );
}

/// Ids of the chart every scenario uses; the server needs UUIDs.
class TestChart {
  final bank = newId();
  final card = newId();
  final groceries = newId();
  final dining = newId();
  final salary = newId();

  Future<void> seed(FinanceStore store) async {
    await store.createAccount(
      Account(id: bank, name: 'Everyday', type: AccountType.transaction),
    );
    await store.createAccount(
      Account(id: card, name: 'Visa', type: AccountType.creditCard),
    );
    await store.createCategory(
      Category(id: groceries, name: 'Groceries', kind: CategoryKind.expense),
    );
    await store.createCategory(
      Category(id: dining, name: 'Dining', kind: CategoryKind.expense),
    );
    await store.createCategory(
      Category(id: salary, name: 'Salary', kind: CategoryKind.income),
    );
  }

  TransactionDraft expense(
    String amount, {
    String? category,
    String date = '2026-07-01',
    String? payee,
    String? id,
  }) => TransactionDraft(
    type: TransactionType.expense,
    accountId: bank,
    amount: m(amount),
    effectiveDate: d(date),
    splits: [Split(category ?? groceries, m(amount))],
    payee: payee,
    status: JournalStatus.posted,
    id: id,
  );

  TransactionDraft income(String amount, {String date = '2026-07-02'}) =>
      TransactionDraft(
        type: TransactionType.income,
        accountId: bank,
        amount: m(amount),
        effectiveDate: d(date),
        splits: [Split(salary, m(amount))],
        status: JournalStatus.posted,
      );
}

/// One device of [user]: an encrypted local store and a sync client that
/// talks to the real server over HTTP.
class E2eDevice {
  E2eDevice._(this.name, this.user, this.store, this.client, this._http);

  final String name;
  final String user;
  final FinanceStore store;
  final SyncClient client;
  final http.Client _http;

  static Future<E2eDevice> create(
    TempDir temp,
    String name, {
    required String user,
  }) async {
    final store = await newStore(temp.sub(name), keys: MemoryKeyStore());
    final httpClient = http.Client();
    final client = SyncClient(
      store,
      httpClient: httpClient,
      baseUri: Uri.parse(baseUrl!),
      accessToken: () async => accessToken(user),
      retry: const RetryPolicy(
        maxAttempts: 3,
        initialDelay: Duration(milliseconds: 50),
        jitter: false,
      ),
      timeout: const Duration(seconds: 20),
    );
    return E2eDevice._(name, user, store, client, httpClient);
  }

  String get deviceId => store.settings.deviceId;

  Future<void> register(RemoteWorkspace workspace) => client.registerDevice(
    workspaceId: workspace.id,
    name: 'Device $name',
    platform: 'linux',
  );

  /// Registers, previews and enables sync, then syncs once.
  Future<SyncBootstrapPreview> join(RemoteWorkspace workspace) async {
    await register(workspace);
    final preview = await client.previewBootstrap(
      remoteWorkspaceId: workspace.id,
    );
    await client.enableSync(preview);
    await client.sync();
    return preview;
  }

  Future<SyncReport> sync({bool uploadAssets = true}) =>
      client.sync(uploadAssets: uploadAssets);

  /// Sends a raw API request and returns the status and decoded body.
  Future<({int status, Object? body})> call(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final response = await client.transport.send(() async {
      final request = http.Request(method, client.transport.resolve(path))
        ..headers.addAll(await client.transport.headers(headers));
      if (body != null) {
        request
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode(body);
      }
      return request;
    }, acceptStatus: (_) => true);
    return (
      status: response.statusCode,
      body: response.body.isEmpty ? null : jsonDecode(response.body),
    );
  }

  Future<void> close() async {
    _http.close();
    await store.close();
  }
}

/// A fresh subject per scenario keeps scenarios independent.
String newUser(String label) => '$label-${newId()}';

/// A small, structurally valid baseline JPEG of [size] bytes (16 x 16
/// pixels), which the server's content sniffing and scan accept.
Uint8List jpegBytes(int size, {int seed = 1}) {
  final header = <int>[
    0xff, 0xd8, // SOI
    0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // APP0 JFIF
    0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 0x01, 0x22,
    0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, // SOF0 16 x 16
    0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00,
    0x3f, 0x00, // SOS
  ];
  final fill = size - header.length - 2;
  return Uint8List.fromList([
    ...header,
    for (var i = 0; i < fill; i++) (i * seed + 7) & 0x7f,
    0xff, 0xd9, // EOI
  ]);
}

/// Retries [action] while it throws [AssetNotYetAvailableException], for
/// the asynchronous scan.
Future<T> eventually<T>(
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      return await action();
    } on AssetNotYetAvailableException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
