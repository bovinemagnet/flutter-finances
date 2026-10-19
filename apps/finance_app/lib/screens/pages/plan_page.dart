import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../data/app_state.dart';
import '../../features/plan/bills_view.dart';
import '../../features/plan/forecast_view.dart';
import '../../features/transactions/transaction_form_model.dart';
import '../../format/formatters.dart';
import '../../widgets/amount_expression.dart';
import '../editors.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  LocalDate? _month;

  /// Hypothetical changes; they alter only the projection (PLAN 03).
  final _whatIf = <ScenarioChange>[];

  Future<void> _addOneOff() async {
    final state = AppScope.of(context);
    final description = TextEditingController();
    final amount = TextEditingController();
    var outgoing = true;
    String? accountId = state.chart.accounts
        .where((a) => a.type.isLiquid && a.includeInForecast)
        .firstOrNull
        ?.id;
    var date = state.today().addDays(7);
    final change = await showDialog<OneOffChange>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('What if…'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Money out')),
                    ButtonSegment(value: false, label: Text('Money in')),
                  ],
                  selected: {outgoing},
                  onSelectionChanged: (v) =>
                      setState(() => outgoing = v.single),
                ),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                TextField(
                  controller: amount,
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: r'$ ',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: [
                    for (final a in state.chart.accounts.where(
                      (a) => a.type.isLiquid,
                    ))
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => accountId = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('On ${formatDate(date)}'),
                  trailing: TextButton(
                    child: const Text('Change'),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime(date.year, date.month, date.day),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null)
                        setState(() => date = LocalDate.fromDateTime(picked));
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final value = evaluateAmountExpression(
                    amount.text,
                    state.currency,
                  );
                  if (accountId == null) return;
                  Navigator.of(context).pop(
                    OneOffChange(
                      id: newId(),
                      date: date,
                      accountId: accountId!,
                      amount: outgoing ? -value : value,
                      description: description.text.trim().isEmpty
                          ? 'What if'
                          : description.text.trim(),
                    ),
                  );
                } on FormatException {
                  return;
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (change != null) setState(() => _whatIf.add(change));
  }

  Future<void> _skipSchedule() async {
    final state = AppScope.of(context);
    final schedule = await showDialog<RecurringSchedule>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('What if this stopped?'),
        children: [
          for (final s in state.schedules)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(s),
              child: Text(s.name),
            ),
        ],
      ),
    );
    if (schedule != null) {
      setState(
        () => _whatIf.add(
          RemoveScheduleChange(id: newId(), scheduleId: schedule.id),
        ),
      );
    }
  }

  Widget _forecastTab(AppState state) {
    final scenario = _whatIf.isEmpty
        ? null
        : Scenario(id: 'what-if', name: 'What if', changes: List.of(_whatIf));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: const Text('What if…'),
                onPressed: _addOneOff,
              ),
              if (state.schedules.isNotEmpty)
                OutlinedButton(
                  onPressed: _skipSchedule,
                  child: const Text('What if a bill stopped'),
                ),
              if (_whatIf.isNotEmpty)
                TextButton(
                  onPressed: () => setState(_whatIf.clear),
                  child: Text('Clear ${_whatIf.length} hypothetical changes'),
                ),
            ],
          ),
        ),
        if (_whatIf.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Hypothetical: nothing is recorded or changed in your accounts.',
            ),
          ),
        Expanded(
          child: ForecastView(forecast: state.forecast(scenario: scenario)),
        ),
      ],
    );
  }

  Future<void> _recordPayment(ScheduledOccurrence occurrence) async {
    final state = AppScope.of(context);
    final schedule = state.schedules.firstWhere(
      (s) => s.id == occurrence.scheduleId,
    );
    final model = TransactionFormModel(state.chart, today: state.today())
      ..type = switch (schedule.kind) {
        ScheduleKind.income => TransactionType.income,
        ScheduleKind.transfer => TransactionType.transfer,
        ScheduleKind.expense => TransactionType.expense,
      }
      ..accountId = schedule.accountId
      ..counterAccountId = schedule.counterAccountId
      ..categoryId = schedule.categoryId
      ..amountText = occurrence.amount.toDecimalString()
      ..payee = schedule.payee ?? schedule.name
      ..effectiveDate = occurrence.dueDate;
    await openTransactionEditor(context, prefilled: model);
    if (!mounted) return;
    final posted = state.ledger.journals
        .where(
          (j) => j.enteredAt.isAfter(
            DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
          ),
        )
        .where((j) => j.payee == model.payee.trim() && j.amount == model.amount)
        .toList();
    final occurrenceState = state
        .occurrenceStates(occurrence.dueDate, occurrence.dueDate)
        .where((s) => s.occurrence.key == occurrence.key)
        .firstOrNull;
    if (posted.isNotEmpty && occurrenceState != null) {
      await state.linkPayment(occurrenceState, posted.last, settles: true);
    }
  }

  Future<void> _linkExisting(ScheduledOccurrence occurrence) async {
    final state = AppScope.of(context);
    final occurrenceState = state
        .occurrenceStates(occurrence.dueDate, occurrence.dueDate)
        .firstWhere((s) => s.occurrence.key == occurrence.key);
    final linked = {for (final p in state.payments) p.journalId};
    final candidates = state.ledger.journals
        .where(
          (j) =>
              j.status.inPostedLedger &&
              j.type != TransactionType.reversal &&
              !linked.contains(j.id) &&
              (j.effectiveDate.daysUntil(occurrence.dueDate)).abs() <= 7,
        )
        .toList();
    final journal = await showDialog<Journal>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Which transaction paid this?'),
        children: [
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No unlinked transactions within 7 days'),
            ),
          for (final j in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(j),
              child: Text(
                '${formatDate(j.effectiveDate)} · ${j.payee ?? ''} · '
                '${j.amount == null ? '' : formatMoney(j.amount!)}',
              ),
            ),
        ],
      ),
    );
    if (journal != null) await state.linkPayment(occurrenceState, journal);
  }

  Future<void> _editOccurrence(ScheduledOccurrence occurrence) async {
    final state = AppScope.of(context);
    final amount = TextEditingController(
      text: occurrence.amount.toDecimalString(),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change this occurrence'),
        content: TextField(
          controller: amount,
          decoration: const InputDecoration(
            labelText: 'Amount',
            prefixText: r'$ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('skip'),
            child: const Text('Skip this one'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (action == null) return;
    Money? newAmount;
    if (action == 'save') {
      try {
        newAmount = evaluateAmountExpression(amount.text, state.currency);
      } on FormatException {
        return;
      }
    }
    await state.saveOverride(
      OccurrenceOverride(
        id: occurrence.overrideId ?? newId(),
        scheduleId: occurrence.scheduleId,
        originalDate: occurrence.originalDate,
        skipped: action == 'skip',
        amount: newAmount,
      ),
    );
  }

  Future<void> _addSchedule() async {
    final state = AppScope.of(context);
    final schedule = await Navigator.of(context).push<RecurringSchedule>(
      MaterialPageRoute(builder: (_) => ScheduleEditor(state: state)),
    );
    if (schedule != null) await state.saveSchedule(schedule);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final today = state.today();
    final month = _month ?? LocalDate(today.year, today.month, 1);
    final monthEnd = LocalDate(
      month.year,
      month.month,
      LocalDate.daysInMonth(month.year, month.month),
    );
    final states = state.occurrenceStates(month, monthEnd);
    final names = {for (final s in state.schedules) s.id: s.name};
    final bills = BillsView(
      states: states,
      scheduleName: (id) => names[id] ?? id,
      onRecordPayment: _recordPayment,
      onLinkPayment: _linkExisting,
      onEditOccurrence: _editOccurrence,
    );
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Bills'),
                Tab(text: 'Calendar'),
                Tab(text: 'Forecast'),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _month = month.addMonths(-1)),
                ),
                Text('${month.month.toString().padLeft(2, '0')}/${month.year}'),
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() => _month = month.addMonths(1)),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  bills,
                  ListView(
                    children: [
                      BillsCalendar(
                        month: month,
                        states: states,
                        onSelectDay: (_) {},
                      ),
                      SizedBox(height: 400, child: bills),
                    ],
                  ),
                  _forecastTab(state),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'schedule',
          onPressed: _addSchedule,
          icon: const Icon(Icons.add_alarm_outlined),
          label: const Text('Add bill or income'),
        ),
      ),
    );
  }
}

/// Creates a recurring bill, income or transfer schedule (PLAN 01).
class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({super.key, required this.state});
  final AppState state;

  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  var _kind = ScheduleKind.expense;
  var _frequency = Frequency.monthly;
  var _estimate = false;
  String? _accountId;
  String? _categoryId;
  late LocalDate _start = widget.state.today();
  var _leadDays = 2;
  String? _error;

  static const _frequencies = {
    Frequency.weekly: 'Weekly',
    Frequency.fortnightly: 'Fortnightly',
    Frequency.monthly: 'Monthly',
    Frequency.quarterly: 'Quarterly',
    Frequency.annually: 'Annually',
  };

  @override
  Widget build(BuildContext context) {
    final chart = widget.state.chart;
    final categories = chart.categories
        .where(
          (c) =>
              c.kind ==
              (_kind == ScheduleKind.income
                  ? CategoryKind.income
                  : CategoryKind.expense),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('New bill or income')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<ScheduleKind>(
            segments: const [
              ButtonSegment(value: ScheduleKind.expense, label: Text('Bill')),
              ButtonSegment(value: ScheduleKind.income, label: Text('Income')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() {
              _kind = s.single;
              _categoryId = null;
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            decoration: InputDecoration(
              labelText: 'Amount',
              prefixText: r'$ ',
              errorText: _error,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          CheckboxListTile(
            value: _estimate,
            title: const Text('The amount is an estimate'),
            onChanged: (v) => setState(() => _estimate = v ?? false),
          ),
          DropdownButtonFormField<Frequency>(
            initialValue: _frequency,
            decoration: const InputDecoration(labelText: 'Repeats'),
            items: [
              for (final e in _frequencies.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (f) => setState(() => _frequency = f!),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [
              for (final a in chart.accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (id) => setState(() => _accountId = id),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [
              for (final c in categories)
                DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (id) => setState(() => _categoryId = id),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('First due'),
            subtitle: Text(formatDate(_start)),
            trailing: TextButton(
              child: const Text('Change'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime(_start.year, _start.month, _start.day),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _start = LocalDate.fromDateTime(picked));
                }
              },
            ),
          ),
          DropdownButtonFormField<int>(
            initialValue: _leadDays,
            decoration: const InputDecoration(labelText: 'Remind me'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('On the day')),
              DropdownMenuItem(value: 1, child: Text('1 day before')),
              DropdownMenuItem(value: 2, child: Text('2 days before')),
              DropdownMenuItem(value: 7, child: Text('A week before')),
            ],
            onChanged: (v) => setState(() => _leadDays = v!),
          ),
          const SizedBox(height: 16),
          const Text(
            'Scheduling never records a payment; you confirm each one.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              Money amount;
              try {
                amount = evaluateAmountExpression(_amount.text, chart.currency);
              } on FormatException {
                setState(() => _error = 'Enter an amount');
                return;
              }
              if (_accountId == null) {
                setState(() => _error = 'Choose an account');
                return;
              }
              Navigator.of(context).pop(
                RecurringSchedule(
                  id: newId(),
                  name: _name.text.trim().isEmpty ? 'Bill' : _name.text.trim(),
                  kind: _kind,
                  recurrence: Recurrence(frequency: _frequency, start: _start),
                  amount: amount,
                  isEstimate: _estimate,
                  accountId: _accountId!,
                  categoryId: _categoryId,
                  payee: _name.text.trim(),
                  reminder: ReminderPreference(leadDays: _leadDays),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
