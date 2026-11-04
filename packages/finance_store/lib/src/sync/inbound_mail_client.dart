import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync_client.dart';
import 'transport.dart';

/// A member's private forwarding address.
@immutable
class InboundAddress {
  const InboundAddress({required this.address, required this.createdAt});

  factory InboundAddress.fromJson(Map<String, Object?> json) => InboundAddress(
    address: json['address'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
  );

  final String address;
  final DateTime createdAt;
}

/// A forwarded attachment waiting to be collected.
@immutable
class InboundDocument {
  const InboundDocument({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.sha256,
    required this.receivedAt,
  });

  factory InboundDocument.fromJson(Map<String, Object?> json) =>
      InboundDocument(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        contentType: json['contentType'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        receivedAt: DateTime.parse(json['receivedAt'] as String).toUtc(),
      );

  final String id;
  final String fileName;
  final String contentType;
  final int sizeBytes;
  final String sha256;
  final DateTime receivedAt;
}

/// An attachment that did not become a receipt, and why.
@immutable
class InboundRejection {
  const InboundRejection({
    required this.fileName,
    required this.code,
    this.detail,
  });

  factory InboundRejection.fromJson(Map<String, Object?> json) =>
      InboundRejection(
        fileName: json['fileName'] as String? ?? '',
        code: json['code'] as String,
        detail: json['detail'] as String?,
      );

  final String fileName;
  final String code;
  final String? detail;
}

/// A forwarded email that did not fully become receipts.
@immutable
class InboundNotice {
  const InboundNotice({
    required this.messageId,
    required this.sender,
    required this.receivedAt,
    required this.outcome,
    required this.rejections,
  });

  factory InboundNotice.fromJson(Map<String, Object?> json) => InboundNotice(
    messageId: json['messageId'] as String,
    sender: json['sender'] as String? ?? '',
    receivedAt: DateTime.parse(json['receivedAt'] as String).toUtc(),
    outcome: json['outcome'] as String,
    rejections: [
      for (final r in json['rejections'] as List? ?? const <Object?>[])
        InboundRejection.fromJson((r as Map).cast<String, Object?>()),
    ],
  );

  final String messageId;
  final String sender;
  final DateTime receivedAt;

  /// `documents`, `no_attachment`, `rejected`, `rate_limited` or `failed`.
  final String outcome;
  final List<InboundRejection> rejections;
}

/// What is waiting for a member.
@immutable
class InboundInbox {
  const InboundInbox({
    required this.documents,
    required this.notices,
    this.recent = const [],
  });

  static const empty = InboundInbox(documents: [], notices: []);

  final List<InboundDocument> documents;
  final List<InboundNotice> notices;

  /// The latest emails and what became of them, newest first.
  final List<InboundNotice> recent;
}

/// The document is no longer on the server, for example because another of the
/// member's devices collected it first.
class InboundDocumentGoneException implements Exception {}

/// The downloaded bytes do not match the document's hash, so they are not
/// saved. The document stays waiting and is tried again.
class InboundDocumentCorruptException implements Exception {}

/// Email receipt forwarding: the member's address and what it received.
class InboundMailClient {
  InboundMailClient(this.transport);

  factory InboundMailClient.of(SyncClient client) =>
      InboundMailClient(client.transport);

  /// An attachment can be 20 MB on a slow connection, which takes far longer
  /// than an ordinary request.
  static const downloadTimeout = Duration(minutes: 5);

  final SyncTransport transport;

  String _addressPath(String workspaceId) =>
      '/v1/workspaces/$workspaceId/inbound-address';

  String _documentsPath(String workspaceId) =>
      '/v1/workspaces/$workspaceId/inbound-documents';

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    bool Function(int status)? acceptStatus,
  }) => transport.send(() async {
    final request = http.Request(method, transport.resolve(path))
      ..headers.addAll(await transport.headers());
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return request;
  }, acceptStatus: acceptStatus);

  static bool _notFound(int status) => status == 404;

  /// Whether this server offers forwarding. An older one, without these
  /// endpoints, does not.
  Future<bool> available() async {
    final response = await _send(
      'GET',
      '/v1/inbound-mail/status',
      acceptStatus: _notFound,
    );
    if (response.statusCode == 404) return false;
    return SyncTransport.decodeObject(response)['available'] == true;
  }

  /// The caller's address, or null while forwarding is turned off.
  Future<InboundAddress?> address(String workspaceId) async {
    final response = await _send(
      'GET',
      _addressPath(workspaceId),
      acceptStatus: _notFound,
    );
    if (response.statusCode == 404) return null;
    return InboundAddress.fromJson(SyncTransport.decodeObject(response));
  }

  /// Turns forwarding on. Any existing address stops working.
  Future<InboundAddress> createOrReplaceAddress(String workspaceId) async =>
      InboundAddress.fromJson(
        SyncTransport.decodeObject(
          await _send('PUT', _addressPath(workspaceId)),
        ),
      );

  Future<void> revokeAddress(String workspaceId) async {
    await _send('DELETE', _addressPath(workspaceId));
  }

  /// The caller's waiting documents and notices. An older server has neither.
  Future<InboundInbox> inbox(String workspaceId) async {
    final response = await _send(
      'GET',
      _documentsPath(workspaceId),
      acceptStatus: _notFound,
    );
    if (response.statusCode == 404) return InboundInbox.empty;
    final json = SyncTransport.decodeObject(response);
    return InboundInbox(
      documents: [
        for (final d in json['documents'] as List? ?? const <Object?>[])
          InboundDocument.fromJson((d as Map).cast<String, Object?>()),
      ],
      notices: [
        for (final n in json['notices'] as List? ?? const <Object?>[])
          InboundNotice.fromJson((n as Map).cast<String, Object?>()),
      ],
      recent: [
        for (final r in json['recent'] as List? ?? const <Object?>[])
          InboundNotice.fromJson((r as Map).cast<String, Object?>()),
      ],
    );
  }

  /// Fetches a document's bytes through a short-lived link, and checks them.
  Future<Uint8List> download(
    String workspaceId,
    InboundDocument document,
  ) async {
    final link = await _send(
      'GET',
      '${_documentsPath(workspaceId)}/${document.id}/download',
      acceptStatus: _notFound,
    );
    if (link.statusCode == 404) throw InboundDocumentGoneException();
    final url = Uri.parse(SyncTransport.decodeObject(link)['url'] as String);
    // A presigned URL carries its own signature and must not see the token.
    final response = await transport.send(
      () async => http.Request('GET', url),
      timeout: downloadTimeout,
    );
    if (sha256.convert(response.bodyBytes).toString() != document.sha256) {
      throw InboundDocumentCorruptException();
    }
    return response.bodyBytes;
  }

  /// Confirms the document is safely saved, so the server deletes its copy.
  Future<void> acknowledge(String workspaceId, String documentId) async {
    await _send(
      'POST',
      '${_documentsPath(workspaceId)}/$documentId/acknowledge',
    );
  }

  /// Reports that the device refused the document, so it is not offered again.
  Future<void> reject(
    String workspaceId,
    String documentId, {
    required String code,
    String? detail,
  }) async {
    await _send(
      'POST',
      '${_documentsPath(workspaceId)}/$documentId/reject',
      body: {'code': code, 'detail': detail},
    );
  }
}
