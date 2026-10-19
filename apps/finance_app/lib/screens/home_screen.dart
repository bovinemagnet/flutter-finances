import 'dart:async';

import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/shell.dart';
import '../data/reminders.dart';
import '../features/receipts/receipt_capture.dart';
import '../features/receipts/receipts_page.dart';
import 'editors.dart';
import 'pages/accounts_page.dart';
import 'pages/budget_page.dart';
import 'pages/overview_page.dart';
import 'pages/plan_page.dart';
import 'pages/reports_page.dart';
import 'pages/settings_page.dart';
import 'pages/transactions_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.syncSection, this.syncStatus});

  final Widget? syncSection;
  final Widget? syncStatus;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  var _selected = Destination.overview;
  StreamSubscription<Object>? _shares;
  String? _reminderSignature;

  /// Reschedules reminders only when schedules or their overrides change.
  void _refreshReminders() {
    final state = AppScope.of(context);
    final signature = [
      for (final s in state.schedules) s.id,
      for (final s in state.store.entities('recurringSchedule')) s.revision,
      for (final o in state.overrides)
        '${o.id}${o.skipped}${o.dueDate}${o.amount}',
    ].join('|');
    if (signature == _reminderSignature) return;
    _reminderSignature = signature;
    final services = AppScope.servicesOf(context);
    syncReminders(
      services.notifications,
      state.schedules,
      state.overrides,
      now: DateTime.now(),
    ).catchError((Object _) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shares != null) return;
    final services = AppScope.servicesOf(context);
    _shares = services.shareInbox.incoming.listen((files) {
      if (mounted) saveCapturedReceipt(context, files);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await services.shareInbox.takePending();
      if (mounted && pending.isNotEmpty) {
        await saveCapturedReceipt(context, pending);
      }
    });
  }

  @override
  void dispose() {
    _shares?.cancel();
    super.dispose();
  }

  void _openEntries(List<String> journalIds) {
    final receiptIds = AppScope.of(context).receipts.receiptJournalIds;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${journalIds.length} entries')),
          body: TransactionsPage(
            onlyJournalIds: journalIds,
            receiptJournalIds: receiptIds,
          ),
        ),
      ),
    );
  }

  void _add(AddAction action) {
    switch (action) {
      case AddAction.expense:
        openTransactionEditor(context, type: TransactionType.expense);
      case AddAction.income:
        openTransactionEditor(context, type: TransactionType.income);
      case AddAction.transfer:
        openTransactionEditor(context, type: TransactionType.transfer);
      case AddAction.receipt:
        scanReceipt(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshReminders();
    });
    final receiptIds = state.receipts.receiptJournalIds;
    final body = switch (_selected) {
      Destination.overview => OverviewPage(
        onNavigate: (d) => setState(() => _selected = d),
        onOpenEntries: _openEntries,
        receiptJournalIds: receiptIds,
      ),
      Destination.transactions => TransactionsPage(
        receiptJournalIds: receiptIds,
      ),
      Destination.budget => BudgetPage(onOpenEntries: _openEntries),
      Destination.receipts => const ReceiptsPage(),
      Destination.plan => const PlanPage(),
      Destination.reports => ReportsPage(
        onOpenEntries: _openEntries,
        receiptJournalIds: receiptIds,
      ),
      Destination.accounts => const AccountsPage(),
      Destination.settings => SettingsPage(syncSection: widget.syncSection),
    };
    return AdaptiveShell(
      selected: _selected,
      onSelect: (d) => setState(() => _selected = d),
      onAdd: _add,
      syncStatus:
          widget.syncStatus ?? _UnsyncedBadge(count: state.unsyncedCount),
      body: KeyedSubtree(key: ValueKey(_selected), child: body),
    );
  }
}

class _UnsyncedBadge extends StatelessWidget {
  const _UnsyncedBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 16),
    child: Tooltip(
      message: count == 0
          ? 'Everything is saved'
          : '$count changes saved on this device only',
      child: Row(
        children: [
          Icon(
            count == 0 ? Icons.check_circle_outline : Icons.cloud_off_outlined,
          ),
          if (count > 0) Text(' $count'),
        ],
      ),
    ),
  );
}
