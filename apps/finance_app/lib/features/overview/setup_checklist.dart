import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'overview_widgets.dart';

/// One thing a new workspace still needs.
class SetupStep {
  const SetupStep({
    required this.title,
    required this.detail,
    required this.done,
    required this.onOpen,
  });

  final String title;
  final String detail;
  final bool done;
  final VoidCallback onOpen;
}

/// What is left to make the Overview's figures meaningful. A finished step is
/// said in words as well as shown by its icon.
class SetupChecklist extends StatelessWidget {
  const SetupChecklist({super.key, required this.steps, required this.onHide});

  final List<SetupStep> steps;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final done = steps.where((s) => s.done).length;
    return OverviewSection(
      title: 'Finish setting up',
      action: 'Hide',
      onAction: onHide,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '$done of ${steps.length} done',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (final step in steps)
          ListTile(
            leading: Icon(
              step.done ? Icons.check_circle : Icons.radio_button_unchecked,
              color: step.done ? palette.accentText : palette.muted,
            ),
            title: Text(step.title),
            subtitle: Text(step.done ? 'Done' : step.detail),
            trailing: step.done ? null : const Icon(Icons.chevron_right),
            onTap: step.done ? null : step.onOpen,
          ),
      ],
    );
  }
}
