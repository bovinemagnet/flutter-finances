import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

typedef Sleep = Future<void> Function(Duration delay);

/// Supplies the current OIDC access token, or null when signed out.
typedef AccessTokenProvider = Future<String?> Function();

/// Supplies the device and workspace headers that scope an API call, keyed
/// by lower-case header name.
typedef ScopeHeaders = Map<String, String> Function();

/// Names the calling device; required by every `/v1/sync/*` endpoint.
const deviceIdHeader = 'x-device-id';

/// Names the workspace; without it the server uses the device's workspace.
const workspaceIdHeader = 'x-workspace-id';

/// Exponential backoff with optional full jitter.
@immutable
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 60),
    this.multiplier = 2,
    this.jitter = true,
  });

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final int multiplier;

  /// Spreads retries of many devices; disable for deterministic tests.
  final bool jitter;

  static final _random = Random();

  /// Delay before retry number [attempt] (1 for the first retry).
  Duration delayFor(int attempt) {
    var micros = initialDelay.inMicroseconds;
    for (var i = 1; i < attempt; i++) {
      micros *= multiplier;
      if (micros >= maxDelay.inMicroseconds) break;
    }
    final capped = min(micros, maxDelay.inMicroseconds);
    return Duration(
      microseconds: jitter ? _random.nextInt(capped + 1) : capped,
    );
  }
}

/// A non-retryable HTTP answer.
class SyncHttpException implements Exception {
  SyncHttpException(this.statusCode, this.body, this.request);
  final int statusCode;
  final String body;
  final String request;

  String? get errorCode {
    try {
      final json = jsonDecode(body);
      return json is Map ? json['error'] as String? : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'SyncHttpException($statusCode $request: $body)';
}

/// Every attempt failed with a transient error; the work stays queued.
class SyncNetworkException implements Exception {
  SyncNetworkException(this.request, this.lastError, this.attempts);
  final String request;
  final Object lastError;
  final int attempts;

  @override
  String toString() =>
      'SyncNetworkException($request after $attempts attempts: $lastError)';
}

class AuthenticationRequiredException implements Exception {
  @override
  String toString() => 'The sync session needs to sign in again';
}

/// HTTP with timeouts and retries. A request is resent unchanged, so a
/// command batch keeps its command ids and a lost response is safe to
/// retry (SYNC 02, A09).
class SyncTransport {
  SyncTransport({
    required this.client,
    required this.baseUri,
    this.accessToken,
    this.scope,
    this.retry = const RetryPolicy(),
    this.timeout = const Duration(seconds: 30),
    Sleep? sleep,
  }) : sleep = sleep ?? Future<void>.delayed;

  final http.Client client;
  final Uri baseUri;
  final AccessTokenProvider? accessToken;

  /// Device and workspace headers sent with every API call.
  final ScopeHeaders? scope;
  final RetryPolicy retry;
  final Duration timeout;
  final Sleep sleep;

  Uri resolve(String path, [Map<String, String>? query]) =>
      baseUri.replace(path: path, queryParameters: query);

  /// JSON, authorisation, device and workspace headers for the API, with
  /// [extra] taking precedence. Never used for presigned object storage
  /// URLs: they carry their own signature and must not see the token.
  Future<Map<String, String>> headers([Map<String, String>? extra]) async {
    final token = await accessToken?.call();
    return {
      'accept': 'application/json',
      'authorization': ?(token == null ? null : 'Bearer $token'),
      ...?scope?.call(),
      ...?extra,
    };
  }

  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
  }) async => decodeObject(
    await send(
      () async =>
          http.Request('GET', resolve(path, query))
            ..headers.addAll(await headers(extraHeaders)),
    ),
  );

  /// A GET whose answer is a JSON array.
  Future<List<Object?>> getJsonList(String path) async {
    final response = await send(
      () async =>
          http.Request('GET', resolve(path))..headers.addAll(await headers()),
    );
    return jsonDecode(response.body) as List<Object?>;
  }

  Future<Map<String, Object?>> postJson(
    String path,
    Object body, {
    Map<String, String>? extraHeaders,
  }) async => decodeObject(
    await send(() async => postRequest(path, body, extraHeaders)),
  );

  /// A JSON POST of [body] with the API headers.
  Future<http.Request> postRequest(
    String path,
    Object body, [
    Map<String, String>? extraHeaders,
  ]) async => http.Request('POST', resolve(path))
    ..headers.addAll(
      await headers({...?extraHeaders, 'content-type': 'application/json'}),
    )
    ..body = jsonEncode(body);

  /// The JSON object in [response], or an empty map for an empty body.
  static Map<String, Object?> decodeObject(http.Response response) {
    if (response.body.isEmpty) return const {};
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  /// Sends a request built by [build], retrying transient failures with
  /// backoff. 4xx answers other than 408 and 429 are thrown at once.
  Future<http.Response> send(
    Future<http.BaseRequest> Function() build, {
    bool Function(int status)? acceptStatus,
  }) async {
    Object? lastError;
    var description = '';
    for (var attempt = 1; attempt <= retry.maxAttempts; attempt++) {
      final request = await build();
      description = '${request.method} ${request.url.path}';
      try {
        final streamed = await client.send(request).timeout(timeout);
        final response = await http.Response.fromStream(streamed)
            .timeout(timeout);
        final status = response.statusCode;
        if (status >= 200 && status < 300) return response;
        if (acceptStatus?.call(status) ?? false) return response;
        if (status == 401) throw AuthenticationRequiredException();
        if (status >= 500 || status == 429 || status == 408) {
          lastError = SyncHttpException(status, response.body, description);
        } else {
          throw SyncHttpException(status, response.body, description);
        }
      } on TimeoutException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      }
      if (attempt < retry.maxAttempts) await sleep(retry.delayFor(attempt));
    }
    throw SyncNetworkException(description, lastError!, retry.maxAttempts);
  }
}
