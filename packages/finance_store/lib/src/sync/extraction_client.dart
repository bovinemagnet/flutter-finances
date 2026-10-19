import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync_client.dart';
import 'transport.dart';

enum ExtractionConsentStatus { none, granted, withdrawn }

/// A workspace's consent to optional cloud extraction (AUTO 02). Consent
/// names the provider and retention the owner was shown.
@immutable
class ExtractionConsent {
  const ExtractionConsent({
    required this.status,
    required this.available,
    this.providerName,
    this.disclosedRetention,
    this.offeredProvider,
    this.offeredRetention,
  });

  factory ExtractionConsent.fromJson(Map<String, Object?> json) =>
      ExtractionConsent(
        status: ExtractionConsentStatus.values.byName(json['status'] as String),
        available: json['available'] as bool? ?? false,
        providerName: json['providerName'] as String?,
        disclosedRetention: json['disclosedRetention'] as String?,
        offeredProvider: json['offeredProvider'] as String?,
        offeredRetention: json['offeredRetention'] as String?,
      );

  final ExtractionConsentStatus status;

  /// False when the service has no extraction provider configured.
  final bool available;
  final String? providerName;
  final String? disclosedRetention;
  final String? offeredProvider;
  final String? offeredRetention;

  bool get granted => status == ExtractionConsentStatus.granted;
}

/// Optional cloud extraction: consent (owners only) and the recognised text
/// of a receipt. The text is untrusted and may only pre-fill a draft.
class ExtractionClient {
  ExtractionClient(this.transport);

  factory ExtractionClient.of(SyncClient client) =>
      ExtractionClient(client.transport);

  final SyncTransport transport;

  String _consent(String workspaceId) =>
      '/v1/workspaces/$workspaceId/extraction-consent';

  Future<ExtractionConsent> consent(String workspaceId) async =>
      ExtractionConsent.fromJson(
        await transport.getJson(_consent(workspaceId)),
      );

  Future<ExtractionConsent> _put(String workspaceId, Object body) async =>
      ExtractionConsent.fromJson(
        SyncTransport.decodeObject(
          await transport.send(
            () async =>
                http.Request('PUT', transport.resolve(_consent(workspaceId)))
                  ..headers.addAll(
                    await transport.headers({
                      'content-type': 'application/json',
                    }),
                  )
                  ..body = jsonEncode(body),
          ),
        ),
      );

  /// Consents to what [offered] names; the server refuses any other
  /// provider or retention.
  Future<ExtractionConsent> grant(
    String workspaceId,
    ExtractionConsent offered,
  ) => _put(workspaceId, {
    'granted': true,
    'providerName': offered.offeredProvider,
    'disclosedRetention': offered.offeredRetention,
  });

  /// Withdraws consent; the server deletes every extraction result.
  Future<ExtractionConsent> withdraw(String workspaceId) =>
      _put(workspaceId, {'granted': false});

  /// The recognised text of [receiptId], or null when there is none.
  Future<String?> extractedText(String receiptId) async {
    final response = await transport.send(
      () async => http.Request(
        'GET',
        transport.resolve('/v1/receipts/$receiptId/extraction'),
      )..headers.addAll(await transport.headers()),
      acceptStatus: (status) => status == 404,
    );
    if (response.statusCode == 404) return null;
    final results =
        SyncTransport.decodeObject(response)['results'] as List? ?? const [];
    if (results.isEmpty) return null;
    return [for (final r in results) (r as Map)['text'] as String? ?? '']
        .join('\n');
  }
}
