import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/page_insets.dart';

/// Renames and merges the tags on entries. Only the tags change, so balances
/// and history stay exactly as they are.
class TagsScreen extends StatelessWidget {
  const TagsScreen({super.key});

  Future<void> _rename(BuildContext context, String from) async {
    final state = AppScope.of(context);
    final existing = state.knownTags.toSet();
    final to = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(from: from, existing: existing),
    );
    if (to != null) await state.renameTag(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tags = state.knownTags;
    final counts = state.tagCounts;
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      body: tags.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No tags yet. Add them when you enter a transaction, then '
                  'see what each one cost under Reports.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.only(bottom: listEndPadding(context)),
              children: [
                for (final tag in tags)
                  ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: Text(tag),
                    subtitle: Text(
                      counts[tag] == 1 ? '1 entry' : '${counts[tag]} entries',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _rename(context, tag),
                  ),
              ],
            ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.from, required this.existing});

  final String from;
  final Set<String> existing;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.from);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final to = normaliseTag(_controller.text);
    final unchanged = to.isEmpty || to == widget.from;
    final merges = !unchanged && widget.existing.contains(to);
    return AlertDialog(
      title: Text('Rename "${widget.from}"'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Tag'),
            onChanged: (_) => setState(() {}),
          ),
          if (merges) ...[
            const SizedBox(height: 12),
            Text(
              '"$to" already exists. Its entries and the ones tagged '
              '"${widget.from}" will share one tag. This cannot be separated '
              'again.',
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: unchanged ? null : () => Navigator.of(context).pop(to),
          child: Text(merges ? 'Merge' : 'Rename'),
        ),
      ],
    );
  }
}
