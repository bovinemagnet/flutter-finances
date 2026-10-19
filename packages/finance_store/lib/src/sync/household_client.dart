import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sync_client.dart';
import 'transport.dart';

/// Household roles: owners manage members, members edit, viewers only read.
enum HouseholdRole { owner, member, viewer }

@immutable
class HouseholdMember {
  const HouseholdMember({
    required this.userId,
    required this.role,
    required this.joinedAt,
    required this.isYou,
  });

  factory HouseholdMember.fromJson(Map<String, Object?> json) =>
      HouseholdMember(
        userId: json['userId'] as String,
        role: HouseholdRole.values.byName(json['role'] as String),
        joinedAt: DateTime.parse(json['joinedAt'] as String),
        isYou: json['you'] as bool? ?? false,
      );

  final String userId;
  final HouseholdRole role;
  final DateTime joinedAt;
  final bool isYou;
}

@immutable
class HouseholdInvitation {
  const HouseholdInvitation({
    required this.id,
    required this.workspaceId,
    required this.role,
    required this.status,
    required this.expiresAt,
    this.token,
  });

  factory HouseholdInvitation.fromJson(Map<String, Object?> json) =>
      HouseholdInvitation(
        id: json['id'] as String,
        workspaceId: json['workspaceId'] as String,
        role: HouseholdRole.values.byName(json['role'] as String),
        status: json['status'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        token: json['token'] as String?,
      );

  final String id;
  final String workspaceId;
  final HouseholdRole role;
  final String status;
  final DateTime expiresAt;

  /// Present only when the invitation was just created; the server never
  /// shows it again.
  final String? token;

  /// A code the owner passes to the person invited, out of band.
  String? get code => token == null ? null : '$workspaceId.$id.$token';
}

/// The parts of an invitation [HouseholdInvitation.code].
@immutable
class InvitationCode {
  const InvitationCode(this.workspaceId, this.invitationId, this.token);

  /// Parses `workspaceId.invitationId.token`; throws [FormatException].
  factory InvitationCode.parse(String code) {
    final parts = code.trim().split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
      throw FormatException('Not an invitation code', code);
    }
    return InvitationCode(parts[0], parts[1], parts[2]);
  }

  final String workspaceId;
  final String invitationId;
  final String token;
}

/// Shared households (P1): invitations, members and roles. Which accounts a
/// member sees is decided by each account's `sharing` field on the server.
class HouseholdClient {
  HouseholdClient(this.transport);

  factory HouseholdClient.of(SyncClient client) =>
      HouseholdClient(client.transport);

  final SyncTransport transport;

  String _base(String workspaceId) => '/v1/workspaces/$workspaceId';

  Future<http.Response> _send(String method, String path, [Object? body]) =>
      transport.send(() async {
        final request = http.Request(method, transport.resolve(path))
          ..headers.addAll(
            await transport.headers({
              if (body != null) 'content-type': 'application/json',
            }),
          );
        if (body != null) request.body = jsonEncode(body);
        return request;
      });

  Future<List<HouseholdMember>> members(String workspaceId) async => [
    for (final m in await transport.getJsonList(
      '${_base(workspaceId)}/members',
    ))
      HouseholdMember.fromJson((m! as Map).cast<String, Object?>()),
  ];

  /// Creates an invitation (owners only); its [HouseholdInvitation.code] is
  /// available only in this answer.
  Future<HouseholdInvitation> invite(
    String workspaceId, {
    HouseholdRole role = HouseholdRole.member,
    int? expiresInHours,
  }) async => HouseholdInvitation.fromJson(
    await transport.postJson('${_base(workspaceId)}/invitations', {
      'role': role.name,
      'expiresInHours': ?expiresInHours,
    }),
  );

  Future<List<HouseholdInvitation>> invitations(String workspaceId) async => [
    for (final i in await transport.getJsonList(
      '${_base(workspaceId)}/invitations',
    ))
      HouseholdInvitation.fromJson((i! as Map).cast<String, Object?>()),
  ];

  Future<void> revokeInvitation(String workspaceId, String invitationId) =>
      _send('DELETE', '${_base(workspaceId)}/invitations/$invitationId');

  /// Joins the household the [code] belongs to; returns the role granted.
  Future<HouseholdRole> accept(InvitationCode code) async {
    final answer = await transport.postJson(
      '${_base(code.workspaceId)}/invitations/${code.invitationId}/accept',
      {'token': code.token},
    );
    return HouseholdRole.values.byName(answer['role'] as String);
  }

  Future<void> changeRole(
    String workspaceId,
    String userId,
    HouseholdRole role,
  ) => _send('PATCH', '${_base(workspaceId)}/members/$userId', {
    'role': role.name,
  });

  /// Removes a member (owners) or leaves (yourself); their devices are
  /// revoked at once.
  Future<void> removeMember(String workspaceId, String userId) =>
      _send('DELETE', '${_base(workspaceId)}/members/$userId');
}
