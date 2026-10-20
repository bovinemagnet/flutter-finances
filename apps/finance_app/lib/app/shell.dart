import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'breakpoints.dart';
import 'section_label.dart';
import 'theme.dart';

/// Primary destinations shown on every surface.
enum Destination {
  overview('Overview', Icons.dashboard_outlined, Icons.dashboard),
  transactions('Transactions', Icons.receipt_long_outlined, Icons.receipt_long),
  budget('Budget', Icons.pie_chart_outline, Icons.pie_chart),
  receipts('Receipts', Icons.document_scanner_outlined, Icons.document_scanner),
  plan('Plan', Icons.event_note_outlined, Icons.event_note),
  reports('Reports', Icons.insights_outlined, Icons.insights, primary: false),
  accounts(
    'Accounts',
    Icons.account_balance_outlined,
    Icons.account_balance,
    primary: false,
  ),
  settings('Settings', Icons.settings_outlined, Icons.settings, primary: false);

  const Destination(
    this.label,
    this.icon,
    this.selectedIcon, {
    this.primary = true,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Secondary destinations are reached from Overview on small screens and
  /// from the sidebar on desktop.
  final bool primary;

  static List<Destination> get primaries =>
      values.where((d) => d.primary).toList();
}

/// Entries offered by the single global add action.
enum AddAction {
  expense('Expense', Icons.remove_circle_outline),
  income('Income', Icons.add_circle_outline),
  transfer('Transfer', Icons.swap_horiz),
  receipt('Scan receipt', Icons.document_scanner_outlined);

  const AddAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

class NavigateIntent extends Intent {
  const NavigateIntent(this.destination);
  final Destination destination;
}

class AddIntent extends Intent {
  const AddIntent(this.action);
  final AddAction action;
}

/// Adaptive navigation chosen from the window width, never from the
/// operating system: bottom navigation on compact widths, a rail on medium
/// widths and a labelled sidebar with keyboard shortcuts on expanded widths.
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
    required this.body,
    this.syncStatus,
  });

  final Destination selected;
  final ValueChanged<Destination> onSelect;
  final ValueChanged<AddAction> onAdd;
  final Widget body;

  /// Small status widget (for example unsynced changes) for the app bar.
  final Widget? syncStatus;

  static final shortcuts = <ShortcutActivator, Intent>{
    for (final (index, destination) in Destination.primaries.indexed)
      SingleActivator(
        LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + index),
        control: true,
      ): NavigateIntent(
        destination,
      ),
    const SingleActivator(LogicalKeyboardKey.keyN, control: true):
        const AddIntent(AddAction.expense),
    const SingleActivator(LogicalKeyboardKey.keyI, control: true):
        const AddIntent(AddAction.income),
    const SingleActivator(LogicalKeyboardKey.keyT, control: true):
        const AddIntent(AddAction.transfer),
    const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true):
        const AddIntent(AddAction.receipt),
  };

  @override
  Widget build(BuildContext context) {
    final windowClass = windowClassFor(MediaQuery.sizeOf(context).width);
    final scaffold = switch (windowClass) {
      WindowClass.compact => _compact(context),
      WindowClass.medium => _railLayout(context, extended: false),
      WindowClass.expanded => _railLayout(context, extended: true),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {
          NavigateIntent: CallbackAction<NavigateIntent>(
            onInvoke: (intent) => onSelect(intent.destination),
          ),
          AddIntent: CallbackAction<AddIntent>(
            onInvoke: (intent) => onAdd(intent.action),
          ),
        },
        child: FocusScope(autofocus: true, child: scaffold),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) =>
      AppBar(title: Text(selected.label), actions: [?syncStatus]);

  Widget _compact(BuildContext context) {
    final primaries = Destination.primaries;
    final index = primaries.indexOf(selected);
    return Scaffold(
      appBar: _appBar(context),
      body: SafeArea(child: body),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AddMenuButton(onAdd: onAdd, small: true),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'scan',
            onPressed: () => onAdd(AddAction.receipt),
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Scan receipt'),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index < 0 ? 0 : index,
        onDestinationSelected: (i) => onSelect(primaries[i]),
        destinations: [
          for (final d in primaries)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }

  Widget _railLayout(BuildContext context, {required bool extended}) {
    if (extended) return _sidebarLayout(context);
    final items = Destination.primaries;
    final index = items.indexOf(selected);
    return Scaffold(
      appBar: _appBar(context),
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: AddMenuButton(onAdd: onAdd),
              ),
              selectedIndex: index < 0 ? null : index,
              onDestinationSelected: (i) => onSelect(items[i]),
              destinations: [
                for (final d in items)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _sidebarLayout(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Sidebar(selected: selected, onSelect: onSelect, onAdd: onAdd),
          const VerticalDivider(width: 1),
          Expanded(
            child: Scaffold(appBar: _appBar(context), body: body),
          ),
        ],
      ),
    ),
  );
}

/// The sidebar's sections; every destination appears exactly once.
const sidebarGroups = <(String, List<Destination>)>[
  (
    'Money',
    [Destination.overview, Destination.transactions, Destination.accounts],
  ),
  ('Plan', [Destination.budget, Destination.plan]),
  ('Review', [Destination.receipts, Destination.reports]),
];

/// Labelled navigation for expanded widths, grouped by task, with the
/// keyboard shortcut shown beside each primary destination.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
  });

  final Destination selected;
  final ValueChanged<Destination> onSelect;
  final ValueChanged<AddAction> onAdd;

  String? _shortcut(Destination d) {
    final index = Destination.primaries.indexOf(d);
    return index < 0 ? null : 'Ctrl ${index + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    Widget item(Destination d) => _SidebarItem(
      destination: d,
      selected: d == selected,
      shortcut: _shortcut(d),
      onTap: () => onSelect(d),
    );
    return Material(
      color: palette.sidebar,
      child: SizedBox(
        width: 248,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 20),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.show_chart,
                      size: 20,
                      color: palette.onAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Finances',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: AddMenuButton(onAdd: onAdd, extended: true),
            ),
            for (final (title, destinations) in sidebarGroups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 20, 12, 6),
                child: SectionLabel(title),
              ),
              for (final d in destinations) item(d),
            ],
            const SizedBox(height: 20),
            Divider(color: palette.line),
            const SizedBox(height: 8),
            item(Destination.settings),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.shortcut,
    required this.onTap,
  });

  final Destination destination;
  final bool selected;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final colour = selected ? palette.accentText : palette.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? palette.accentSoft : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      selected ? destination.selectedIcon : destination.icon,
                      size: 20,
                      color: selected ? palette.accentText : palette.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        destination.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colour,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (shortcut != null)
                      Text(
                        shortcut!,
                        style: palette.figure(
                          size: 10,
                          weight: FontWeight.w500,
                          color: selected ? palette.accentText : palette.muted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The single global add action (expense, income, transfer, receipt).
class AddMenuButton extends StatelessWidget {
  const AddMenuButton({
    super.key,
    required this.onAdd,
    this.small = false,
    this.extended = false,
  });

  final ValueChanged<AddAction> onAdd;
  final bool small;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final action in AddAction.values)
          MenuItemButton(
            leadingIcon: Icon(action.icon),
            onPressed: () => onAdd(action),
            child: Text(action.label),
          ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (extended) {
          return FloatingActionButton.extended(
            heroTag: 'add',
            onPressed: toggle,
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          );
        }
        return FloatingActionButton(
          heroTag: 'add',
          mini: small,
          tooltip: 'Add',
          onPressed: toggle,
          child: const Icon(Icons.add),
        );
      },
    );
  }
}
