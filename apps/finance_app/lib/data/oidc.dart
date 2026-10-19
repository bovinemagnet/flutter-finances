import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:finance_store/finance_store.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Identity provider settings for synced mode (SEC 01). Public client only:
/// the application never holds a client secret.
@immutable
class OidcConfig {
  const OidcConfig({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    this.scopes = const ['openid', 'profile', 'offline_access'],
  });

  final String issuer;
  final String clientId;
  final String redirectUri;
  final List<String> scopes;
}

class OidcException implements Exception {
  OidcException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Proof Key for Code Exchange (RFC 7636) with the S256 method.
@immutable
class Pkce {
  const Pkce(this.verifier, this.challenge);

  factory Pkce.generate() {
    final verifier = _randomUrlSafe(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return Pkce(verifier, challenge);
  }

  final String verifier;
  final String challenge;
}

const _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

String _randomUrlSafe(int length) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => _unreserved[random.nextInt(_unreserved.length)],
  ).join();
}

@immutable
class AuthorisationRequest {
  const AuthorisationRequest(this.uri, this.state, this.pkce);
  final Uri uri;
  final String state;
  final Pkce pkce;
}

/// Where the rotating refresh token is kept between launches.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String refreshToken);
  Future<void> delete();
}

class MemoryTokenStore implements TokenStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String refreshToken) async => _value = refreshToken;
  @override
  Future<void> delete() async => _value = null;
}

/// Keeps the refresh token in the platform key store; when none is
/// available the token lives only in memory and the user signs in again
/// after a restart.
class SecureTokenStore implements TokenStore {
  SecureTokenStore(this.keyStore);
  final SecureKeyStore keyStore;
  final _memory = MemoryTokenStore();
  static const _name = 'finance_app/oidc/refresh-token';

  @override
  Future<String?> read() async {
    if (!await keyStore.isAvailable()) return _memory.read();
    final bytes = await keyStore.read(_name);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<void> write(String refreshToken) async {
    if (!await keyStore.isAvailable()) return _memory.write(refreshToken);
    await keyStore.write(_name, utf8.encode(refreshToken));
  }

  @override
  Future<void> delete() async {
    await _memory.delete();
    if (await keyStore.isAvailable()) await keyStore.delete(_name);
  }
}

/// Authorisation code flow with PKCE through the system browser, with short
/// lived access tokens and rotated refresh tokens.
class OidcSession {
  OidcSession(
    this.config, {
    required this.tokens,
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? (() => DateTime.now().toUtc());

  final OidcConfig config;
  final TokenStore tokens;
  final http.Client _http;
  final DateTime Function() _clock;

  Map<String, Object?>? _discovery;
  String? _accessToken;
  DateTime? _expiresAt;

  Future<Map<String, Object?>> _metadata() async {
    if (_discovery != null) return _discovery!;
    final response = await _http.get(
      Uri.parse('${config.issuer}/.well-known/openid-configuration'),
    );
    if (response.statusCode != 200) {
      throw OidcException('The sign-in service could not be reached');
    }
    return _discovery = jsonDecode(response.body) as Map<String, Object?>;
  }

  Future<AuthorisationRequest> authorisationRequest() async {
    final metadata = await _metadata();
    final pkce = Pkce.generate();
    final state = _randomUrlSafe(32);
    final uri = Uri.parse(metadata['authorization_endpoint'] as String).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': config.clientId,
        'redirect_uri': config.redirectUri,
        'scope': config.scopes.join(' '),
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    );
    return AuthorisationRequest(uri, state, pkce);
  }

  /// Completes sign-in from the redirect the browser returned.
  Future<void> completeSignIn(
    AuthorisationRequest request,
    String callbackUrl,
  ) async {
    final params = Uri.parse(callbackUrl).queryParameters;
    if (params['error'] != null) {
      throw OidcException('Sign-in was not completed: ${params['error']}');
    }
    if (params['state'] != request.state) {
      throw OidcException('The sign-in response did not match this request');
    }
    final code = params['code'];
    if (code == null) throw OidcException('The sign-in response had no code');
    await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': config.redirectUri,
      'client_id': config.clientId,
      'code_verifier': request.pkce.verifier,
    });
  }

  Future<void> _token(Map<String, String> form) async {
    final metadata = await _metadata();
    final response = await _http.post(
      Uri.parse(metadata['token_endpoint'] as String),
      body: form,
    );
    if (response.statusCode != 200) {
      if (form['grant_type'] == 'refresh_token') {
        await tokens.delete();
        _accessToken = null;
        throw AuthenticationRequiredException();
      }
      throw OidcException('Sign-in failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    _accessToken = body['access_token'] as String;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 300;
    // Refresh slightly early so a request never carries an expired token.
    _expiresAt = _clock().add(Duration(seconds: expiresIn - 30));
    final refresh = body['refresh_token'] as String?;
    if (refresh != null) await tokens.write(refresh);
  }

  Future<bool> get isSignedIn async => await tokens.read() != null;

  /// A valid access token, refreshing when needed; null when signed out.
  Future<String?> accessToken() async {
    if (_accessToken != null &&
        _expiresAt != null &&
        _clock().isBefore(_expiresAt!)) {
      return _accessToken;
    }
    final refresh = await tokens.read();
    if (refresh == null) return null;
    await _token({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': config.clientId,
    });
    return _accessToken;
  }

  Future<void> signOut() async {
    _accessToken = null;
    _expiresAt = null;
    await tokens.delete();
  }
}
