import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';

/// Categorisation rules (AUTO 01). Rules apply only after a preview, never
/// override a category the user chose, and can be undone as a group.
class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final state = AppScope.of(context);
    final merchant = TextEditingController();
    String? categoryId;
    final rule = await showDialog<CategorisationRule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: merchant,
                decoration: const InputDecoration(
                  labelText: 'When the merchant contains',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: categoryId,
                decoration: const InputDecoration(labelText: 'Use category'),
                items: [
                  for (final c in state.chart.categories.where(
                    (c) => !c.archived,
                  ))
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => categoryId = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: merchant.text.trim().isEmpty && categoryId == null
                  ? null
                  : () => Navigator.of(context).pop(
                      CategorisationRule(
                        id: newId(),
                        name: merchant.text.trim(),
                        categoryId: categoryId!,
                        merchant: merchant.text.trim(),
                      ),
                    ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (rule != null) await state.saveRule(rule);
  }

  Future<void> _apply(BuildContext context) async {
    final state = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final preview = state.previewRules();
    if (preview.changes.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No entries would change')),
      );
      return;
    }
    final name = {for (final c in state.chart.categories) c.id: c.name};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Change ${preview.changes.length} entries?'),
        content: SizedBox(
          width: 400,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final change in preview.changes.take(50))
                Text(
                  '${name[change.fromCategoryId]} → ${name[change.toCategoryId]}',
                ),
              if (preview.skipped.isNotEmpty)
                Text(
                  '${preview.skipped.length} entries are left as you categorised them.',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final undo = await state.applyRules(preview);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Changed ${undo.length} entries'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => state.undoRules(undo),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rules = state.rules;
    final name = {for (final c in state.chart.categories) c.id: c.name};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categorisation rules'),
        actions: [
          TextButton(
            onPressed: () => _apply(context),
            child: const Text('Apply to existing'),
          ),
        ],
      ),
      body: rules.isEmpty
          ? const Center(child: Text('No rules yet'))
          : ListView(
              children: [
                for (final rule in rules)
                  ListTile(
                    title: Text(
                      'Merchant contains "${rule.merchant ?? rule.name}"',
                    ),
                    subtitle: Text(
                      '→ ${name[rule.categoryId] ?? rule.categoryId}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Delete rule',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => state.deleteRule(rule.id),
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'rule',
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('New rule'),
      ),
    );
  }
}
