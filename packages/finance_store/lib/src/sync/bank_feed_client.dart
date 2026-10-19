import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync_client.dart';
import 'transport.dart';

enum BankConsentStatus { pending, active, expired, revoked }

@immutable
class BankSharedAccount {
  const BankSharedAccount({
    required this.id,
    required this.name,
    required this.type,
    this.maskedNumber,
  });

  factory BankSharedAccount.fromJson(Map<String, Object?> json) =>
      BankSharedAccount(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? '',
        maskedNumber: json['maskedNumber'] as String?,
      );

  final String id;
  final String name;
  final String type;
  final String? maskedNumber;
}

/// A bank feed connection with its consent and feed health (BANK 01-03).
@immutable
class BankConnection {
  const BankConnection({
    required this.id,
    required this.provider,
    required this.institutionName,
    required this.sharedAccounts,
    required this.purpose,
    required this.consentStatus,
    required this.stale,
    this.consentExpiresAt,
    this.lastSuccessfulRefreshAt,
    this.errorCode,
    this.consentUrl,
  });

  factory BankConnection.fromJson(Map<String, Object?> json) {
    DateTime? instant(String key) {
      final value = json[key] as String?;
      return value == null ? null : DateTime.parse(value);
    }

    final institution = (json['institution'] as Map?)?.cast<String, Object?>();
    final error = (json['error'] as Map?)?.cast<String, Object?>();
    return BankConnection(
      id: json['id'] as String,
      provider: json['provider'] as String,
      institutionName:
          institution?['name'] as String? ?? json['provider'] as String,
      sharedAccounts: [
        for (final a in json['sharedAccounts'] as List? ?? const [])
          BankSharedAccount.fromJson((a as Map).cast<String, Object?>()),
      ],
      purpose: json['purpose'] as String? ?? '',
      consentStatus: BankConsentStatus.values.byName(
        json['consentStatus'] as String,
      ),
      stale: json['stale'] as bool? ?? false,
      consentExpiresAt: instant('consentExpiresAt'),
      lastSuccessfulRefreshAt: instant('lastSuccessfulRefreshAt'),
      errorCode: error?['code'] as String?,
      consentUrl: json['consentUrl'] as String?,
    );
  }

  final String id;
  final String provider;
  final String institutionName;
  final List<BankSharedAccount> sharedAccounts;
  final String purpose;
  final BankConsentStatus consentStatus;

  /// The feed has not refreshed for a while; never present it as current.
  final bool stale;
  final DateTime? consentExpiresAt;
  final DateTime? lastSuccessfulRefreshAt;
  final String? errorCode;

  /// Where the user consents at the provider, when consent is still needed.
  final String? consentUrl;
}

enum BankProposalKind { newTransaction, settlesPending, reversal }

/// A provider transaction offered as an entry; it is never posted unless
/// the user accepts it.
@immutable
class BankProposal {
  const BankProposal({
    required this.recordId,
    required this.accountId,
    required this.pending,
    required this.amountMinor,
    required this.currency,
    required this.date,
    required this.description,
    required this.kind,
    required this.proposalStatus,
    this.relatedRecordId,
    this.journalId,
  });

  factory BankProposal.fromJson(Map<String, Object?> json) => BankProposal(
    recordId: json['recordId'] as String,
    accountId: json['accountId'] as String,
    pending: json['status'] == 'pending',
    amountMinor: (json['amountMinor'] as num).toInt(),
    currency: json['currency'] as String,
    date: json['date'] as String,
    description: json['description'] as String? ?? '',
    kind: switch (json['kind']) {
      'settles_pending' => BankProposalKind.settlesPending,
      'reversal' => BankProposalKind.reversal,
      _ => BankProposalKind.newTransaction,
    },
    proposalStatus: json['proposalStatus'] as String,
    relatedRecordId: json['relatedRecordId'] as String?,
    journalId: json['journalId'] as String?,
  );

  final String recordId;

  /// The provider's account id, not a local account.
  final String accountId;
  final bool pending;

  /// Signed: negative is money out.
  final int amountMinor;
  final String currency;

  /// ISO date (`yyyy-MM-dd`).
  final String date;

  /// Untrusted provider text.
  final String description;
  final BankProposalKind kind;
  final String proposalStatus;
  final String? relatedRecordId;
  final String? journalId;

  bool get isMoneyOut => amountMinor < 0;
}

/// Bank feed connections and proposals. No provider credentials ever pass
/// through the client: consent happens at the provider.
class BankFeedClient {
  BankFeedClient(this.transport);

  factory BankFeedClient.of(SyncClient client) =>
      BankFeedClient(client.transport);

  final SyncTransport transport;

  static const _connections = '/v1/bank-feeds/connections';

  Future<http.Response> _send(String method, String path) => transport.send(
    () async =>
        http.Request(method, transport.resolve(path))
          ..headers.addAll(await transport.headers()),
  );

  Future<BankConnection> connect({
    required String provider,
    required String purpose,
    String? institutionId,
  }) async => BankConnection.fromJson(
    await transport.postJson(_connections, {
      'provider': provider,
      'institutionId': ?institutionId,
      'purpose': purpose,
    }),
  );

  Future<List<BankConnection>> connections() async => [
    for (final c in await transport.getJsonList(_connections))
      BankConnection.fromJson((c! as Map).cast<String, Object?>()),
  ];

  /// Queues a refresh; returns the job id.
  Future<String> refresh(String connectionId) async =>
      (await transport.postJson(
            '$_connections/$connectionId/refresh',
            const {},
          ))['jobId']
          as String;

  Future<BankConnection> reconnect(String connectionId) async =>
      BankConnection.fromJson(
        await transport.postJson(
          '$_connections/$connectionId/reconnect',
          const {},
        ),
      );

  Future<BankConnection> revoke(String connectionId) async =>
      BankConnection.fromJson(
        SyncTransport.decodeObject(
          await _send('DELETE', '$_connections/$connectionId'),
        ),
      );

  Future<List<BankProposal>> proposals(
    String connectionId, {
    String status = 'open',
  }) async {
    final answer = await transport.getJson(
      '/v1/bank-feeds/$connectionId/proposals',
      query: {'status': status},
    );
    return [
      for (final p in answer['proposals'] as List? ?? const [])
        BankProposal.fromJson((p as Map).cast<String, Object?>()),
    ];
  }

  /// Records that the user posted [journalId] from the proposal.
  Future<void> accept(
    String connectionId,
    String recordId, {
    required String journalId,
  }) => transport.postJson(
    '/v1/bank-feeds/$connectionId/proposals/$recordId/decision',
    {'decision': 'accepted', 'journalId': journalId},
  );

  Future<void> dismiss(String connectionId, String recordId) =>
      transport.postJson(
        '/v1/bank-feeds/$connectionId/proposals/$recordId/decision',
        {'decision': 'dismissed'},
      );
}
