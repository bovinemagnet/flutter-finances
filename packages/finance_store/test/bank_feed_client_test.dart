import 'dart:convert';

import 'package:finance_store/finance_store.dart';
import 'package:finance_store/src/sync/transport.dart' show SyncTransport;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _connection = {
  'id': 'c1',
  'provider': 'sandbox',
  'institution': {'id': 'sandbox-bank', 'name': 'Sandbox Bank'},
  'sharedAccounts': [
    {
      'id': 'sb-everyday',
      'name': 'Everyday',
      'type': 'transaction',
      'maskedNumber': 'xxxx1234',
    },
  ],
  'dataScope': ['bank:accounts.basic:read', 'bank:transactions:read'],
  'purpose': 'Suggest entries from my bank transactions',
  'consentStatus': 'active',
  'consentExpiresAt': '2027-01-18T00:00:00Z',
  'lastSuccessfulRefreshAt': '2026-10-18T00:00:00Z',
  'stale': true,
  'error': {'code': 'RATE_LIMITED', 'at': '2026-10-19T00:00:00Z'},
  'createdAt': '2026-10-18T00:00:00Z',
};

const _proposal = {
  'recordId': 'r1',
  'accountId': 'sb-everyday',
  'providerTransactionId': 'tx-1',
  'status': 'posted',
  'amountMinor': -4250,
  'currency': 'AUD',
  'date': '2026-10-18',
  'description': 'GROCER 123',
  'kind': 'new',
  'proposalStatus': 'open',
  'firstSeenAt': '2026-10-18T01:00:00Z',
};

void main() {
  late List<http.Request> requests;
  late BankFeedClient client;

  setUp(() {
    requests = [];
    final http.Client mock = MockClient((request) async {
      requests.add(request);
      return switch ((request.method, request.url.path)) {
        ('POST', '/v1/bank-feeds/connections') => http.Response(
          jsonEncode(_connection),
          201,
        ),
        ('GET', '/v1/bank-feeds/connections') => http.Response(
          jsonEncode([_connection]),
          200,
        ),
        ('POST', '/v1/bank-feeds/connections/c1/refresh') => http.Response(
          jsonEncode({'jobId': 'j1'}),
          202,
        ),
        ('POST', '/v1/bank-feeds/connections/c1/reconnect') ||
        (
          'DELETE',
          '/v1/bank-feeds/connections/c1',
        ) => http.Response(jsonEncode(_connection), 200),
        ('GET', '/v1/bank-feeds/c1/proposals') => http.Response(
          jsonEncode({
            'connectionId': 'c1',
            'proposals': [_proposal],
          }),
          200,
        ),
        ('POST', '/v1/bank-feeds/c1/proposals/r1/decision') => http.Response(
          jsonEncode({
            ..._proposal,
            'proposalStatus': 'accepted',
            'journalId': 'j-9',
          }),
          200,
        ),
        _ => http.Response('', 404),
      };
    });
    client = BankFeedClient(
      SyncTransport(
        client: mock,
        baseUri: Uri.parse('https://sync.test'),
        accessToken: () async => 'token',
      ),
    );
  });

  test('connecting sends the provider and purpose, never a password', () async {
    final connection = await client.connect(
      provider: 'sandbox',
      purpose: 'Suggest entries from my bank transactions',
    );
    expect(jsonDecode(requests.single.body), {
      'provider': 'sandbox',
      'purpose': 'Suggest entries from my bank transactions',
    });
    expect(connection.institutionName, 'Sandbox Bank');
    expect(connection.consentStatus, BankConsentStatus.active);
    expect(connection.sharedAccounts.single.name, 'Everyday');
  });

  test('connections report health, staleness and errors', () async {
    final connection = (await client.connections()).single;
    expect(connection.stale, isTrue);
    expect(connection.errorCode, 'RATE_LIMITED');
    expect(connection.lastSuccessfulRefreshAt, DateTime.utc(2026, 10, 18));
    expect(connection.consentUrl, isNull);
  });

  test('refresh, reconnect and revoke use the connection paths', () async {
    expect(await client.refresh('c1'), 'j1');
    await client.reconnect('c1');
    await client.revoke('c1');
    expect(requests.map((r) => '${r.method} ${r.url.path}'), [
      'POST /v1/bank-feeds/connections/c1/refresh',
      'POST /v1/bank-feeds/connections/c1/reconnect',
      'DELETE /v1/bank-feeds/connections/c1',
    ]);
  });

  test('proposals are parsed with signed amounts and their kind', () async {
    final proposal = (await client.proposals('c1')).single;
    expect(requests.single.url.queryParameters, {'status': 'open'});
    expect(proposal.amountMinor, -4250);
    expect(proposal.isMoneyOut, isTrue);
    expect(proposal.date, '2026-10-18');
    expect(proposal.kind, BankProposalKind.newTransaction);
    expect(proposal.pending, isFalse);
    expect(proposal.description, 'GROCER 123');
  });

  test('accepting names the journal; dismissing sends no journal', () async {
    await client.accept('c1', 'r1', journalId: 'j-9');
    await client.dismiss('c1', 'r1');
    expect(jsonDecode(requests.first.body), {
      'decision': 'accepted',
      'journalId': 'j-9',
    });
    expect(jsonDecode(requests.last.body), {'decision': 'dismissed'});
  });
}
