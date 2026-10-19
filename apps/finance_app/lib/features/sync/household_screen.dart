import 'package:finance_store/finance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/sync_controller.dart';

const _roleLabels = {
  HouseholdRole.owner: 'Owner',
  HouseholdRole.member: 'Member',
  HouseholdRole.viewer: 'Viewer (read only)',
};

/// Household members and invitations (P1 shared households). Each account
/// stays private to its creator unless shared in the account settings.
class HouseholdScreen extends StatefulWidget {
  const HouseholdScreen({super.key, required this.controller});
  final SyncController controller;

  @override
  State<HouseholdScreen> createState() => _HouseholdScreenState();
}

class _HouseholdScreenState extends State<HouseholdScreen> {
  late Future<(List<HouseholdMember>, List<HouseholdInvitation>)> _load =
      _fetch();

  HouseholdClient get _household => widget.controller.household;
  String get _workspace => widget.controller.workspaceId;

  Future<(List<HouseholdMember>, List<HouseholdInvitation>)> _fetch() async {
    final members = await _household.members(_workspace);
    final isOwner = members.any(
      (m) => m.isYou && m.role == HouseholdRole.owner,
    );
    final invitations = isOwner
        ? await _household.invitations(_workspace)
        : const <HouseholdInvitation>[];
    return (members, invitations);
  }

  void _reload() => setState(() {
    _load = _fetch();
  });

  Future<void> _invite() async {
    final role = await showDialog<HouseholdRole>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Invite someone as'),
        children: [
          for (final role in [HouseholdRole.member, HouseholdRole.viewer])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(role),
              child: Text(_roleLabels[role]!),
            ),
        ],
      ),
    );
    if (role == null) return;
    final invitation = await _household.invite(
      _workspace,
      role: role,
      expiresInHours: 168,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Invitation code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Send this code privately. It works once, for seven days, '
              'and is not shown again. They enter it under "Use my synced data".',
            ),
            const SizedBox(height: 12),
            SelectableText(invitation.code!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: invitation.code!)),
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Household')),
      body: FutureBuilder(
        future: _load,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'The household could not be loaded: ${snapshot.error}',
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (members, invitations) = snapshot.data!;
          final isOwner = members.any(
            (m) => m.isYou && m.role == HouseholdRole.owner,
          );
          return ListView(
            children: [
              const ListTile(
                title: Text(
                  'Accounts stay private to whoever created them unless '
                  '"Share with my household" is switched on for the account.',
                ),
              ),
              for (final member in members)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(
                    member.isYou
                        ? 'You'
                        : 'Member since ${member.joinedAt.toLocal().toString().split(' ').first}',
                  ),
                  subtitle: Text(_roleLabels[member.role]!),
                  trailing: (isOwner && !member.isYou) || member.isYou
                      ? PopupMenuButton<String>(
                          tooltip: 'Actions',
                          onSelected: (action) async {
                            if (action == 'remove') {
                              await _household.removeMember(
                                _workspace,
                                member.userId,
                              );
                            } else {
                              await _household.changeRole(
                                _workspace,
                                member.userId,
                                HouseholdRole.values.byName(action),
                              );
                            }
                            _reload();
                          },
                          itemBuilder: (context) => [
                            if (isOwner && !member.isYou)
                              for (final role in HouseholdRole.values)
                                PopupMenuItem(
                                  value: role.name,
                                  child: Text('Make ${_roleLabels[role]}'),
                                ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(
                                member.isYou ? 'Leave household' : 'Remove',
                              ),
                            ),
                          ],
                        )
                      : null,
                ),
              if (invitations.isNotEmpty) const Divider(),
              for (final invitation in invitations.where(
                (i) => i.status == 'pending',
              ))
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: Text('Invitation (${_roleLabels[invitation.role]})'),
                  subtitle: Text(
                    'Expires ${invitation.expiresAt.toLocal().toString().split('.').first}',
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      await _household.revokeInvitation(
                        _workspace,
                        invitation.id,
                      );
                      _reload();
                    },
                    child: const Text('Revoke'),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'invite',
        onPressed: _invite,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Invite'),
      ),
    );
  }
}
