import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:finance_app/data/oidc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const config = OidcConfig(
    issuer: 'https://id.example.com/realms/finance',
    clientId: 'finance-app',
    redirectUri: 'com.paulsnow.finance.app:/oauth',
  );

  http.Client fakeIdp(List<Map<String, String>> tokenRequests,
      {String refreshToken = 'refresh-2'}) {
    return MockClient((request) async {
      if (request.url.path.endsWith('/.well-known/openid-configuration')) {
        return http.Response(jsonEncode({
          'issuer': config.issuer,
          'authorization_endpoint': '${config.issuer}/protocol/openid-connect/auth',
          'token_endpoint': '${config.issuer}/protocol/openid-connect/token',
        }), 200);
      }
      tokenRequests.add(request.bodyFields);
      return http.Response(jsonEncode({
        'access_token': 'access-${tokenRequests.length}',
        'refresh_token': refreshToken,
        'expires_in': 300,
        'token_type': 'Bearer',
      }), 200);
    });
  }

  test('PKCE challenge is the unpadded base64url SHA-256 of the verifier', () {
    final pkce = Pkce.generate();
    expect(pkce.verifier.length, inInclusiveRange(43, 128));
    expect(pkce.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
    final expected = base64Url
        .encode(sha256.convert(ascii.encode(pkce.verifier)).bytes)
        .replaceAll('=', '');
    expect(pkce.challenge, expected);
  });

  test('builds an authorisation request with S256, state and no secret', () async {
    final session = OidcSession(config, httpClient: fakeIdp([]), tokens: MemoryTokenStore());
    final request = await session.authorisationRequest();
    final uri = request.uri;
    expect(uri.path, endsWith('/auth'));
    expect(uri.queryParameters['response_type'], 'code');
    expect(uri.queryParameters['code_challenge_method'], 'S256');
    expect(uri.queryParameters['client_id'], 'finance-app');
    expect(uri.queryParameters['scope'], contains('offline_access'));
    expect(uri.queryParameters['state'], request.state);
    expect(uri.queryParameters.containsKey('client_secret'), isFalse);
  });

  test('exchanges the code, rejects a wrong state and rotates refresh tokens',
      () async {
    final requests = <Map<String, String>>[];
    final tokens = MemoryTokenStore();
    var now = DateTime.utc(2026, 10, 19, 10);
    final session = OidcSession(config,
        httpClient: fakeIdp(requests), tokens: tokens, clock: () => now);
    final request = await session.authorisationRequest();
    await expectLater(
      session.completeSignIn(request, '${config.redirectUri}?code=abc&state=wrong'),
      throwsA(isA<OidcException>()),
    );
    await session.completeSignIn(request, '${config.redirectUri}?code=abc&state=${request.state}');
    expect(requests.single['grant_type'], 'authorization_code');
    expect(requests.single['code_verifier'], request.pkce.verifier);
    expect(await session.accessToken(), 'access-1');
    expect(await tokens.read(), 'refresh-2');

    now = now.add(const Duration(minutes: 10));
    expect(await session.accessToken(), 'access-2');
    expect(requests.last['grant_type'], 'refresh_token');
    expect(requests.last['refresh_token'], 'refresh-2');
  });

  test('signing out forgets tokens', () async {
    final tokens = MemoryTokenStore();
    await tokens.write('refresh');
    final session = OidcSession(config, httpClient: fakeIdp([]), tokens: tokens);
    await session.signOut();
    expect(await tokens.read(), isNull);
    expect(await session.accessToken(), isNull);
  });
}
