import 'dart:convert';

import 'package:finance_store/finance_store.dart';
import 'package:finance_store/src/sync/transport.dart' show SyncTransport;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late List<http.Request> requests;
  late HouseholdClient client;

  setUp(() {
    requests = [];
    final http.Client mock = MockClient((request) async {
      requests.add(request);
      return switch ((request.method, request.url.path)) {
        ('POST', '/v1/workspaces/w1/invitations') => http.Response(
          jsonEncode({
            'id': 'i1',
            'workspaceId': 'w1',
            'role': 'viewer',
            'status': 'pending',
            'createdAt': '2026-10-20T00:00:00Z',
            'expiresAt': '2026-10-27T00:00:00Z',
            'token': 'secret',
          }),
          201,
        ),
        ('POST', '/v1/workspaces/w1/invitations/i1/accept') => http.Response(
          jsonEncode({'workspaceId': 'w1', 'role': 'viewer'}),
          200,
        ),
        ('GET', '/v1/workspaces/w1/members') => http.Response(
          jsonEncode([
            {
              'userId': 'u1',
              'role': 'owner',
              'joinedAt': '2026-10-01T00:00:00Z',
              'you': true,
            },
          ]),
          200,
        ),
        _ => http.Response('', 204),
      };
    });
    client = HouseholdClient(
      SyncTransport(
        client: mock,
        baseUri: Uri.parse('https://sync.test'),
        accessToken: () async => 'token',
      ),
    );
  });

  test('an invitation returns a one-time code that round-trips', () async {
    final invitation = await client.invite(
      'w1',
      role: HouseholdRole.viewer,
      expiresInHours: 168,
    );
    expect(jsonDecode(requests.single.body), {
      'role': 'viewer',
      'expiresInHours': 168,
    });
    expect(requests.single.headers['authorization'], 'Bearer token');
    final code = InvitationCode.parse(invitation.code!);
    expect(await client.accept(code), HouseholdRole.viewer);
    expect(jsonDecode(requests.last.body), {'token': 'secret'});
  });

  test(
    'members, role changes and removal use the household endpoints',
    () async {
      final members = await client.members('w1');
      expect(members.single.isYou, isTrue);
      await client.changeRole('w1', 'u2', HouseholdRole.viewer);
      await client.removeMember('w1', 'u2');
      expect(requests.map((r) => '${r.method} ${r.url.path}'), [
        'GET /v1/workspaces/w1/members',
        'PATCH /v1/workspaces/w1/members/u2',
        'DELETE /v1/workspaces/w1/members/u2',
      ]);
      expect(jsonDecode(requests[1].body), {'role': 'viewer'});
    },
  );

  test('malformed invitation codes are rejected', () {
    expect(() => InvitationCode.parse('nonsense'), throwsFormatException);
  });
}
