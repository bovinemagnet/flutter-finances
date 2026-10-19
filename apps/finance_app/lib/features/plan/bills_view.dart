import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

const occurrenceStatusLabels = {
  OccurrenceStatus.upcoming: 'Upcoming',
  OccurrenceStatus.due: 'Due today',
  OccurrenceStatus.paid: 'Paid',
  OccurrenceStatus.partiallyPaid: 'Partly paid',
  OccurrenceStatus.unpaid: 'Unpaid',
  OccurrenceStatus.unknown: 'Not yet seen in account data',
  OccurrenceStatus.skipped: 'Skipped',
};

/// Upcoming bills and income with their payment state (PLAN 01, PLAN 02).
///
/// Scheduling never posts anything: "Record payment" opens the normal entry
/// form, and "Link" attaches an existing transaction, marking it paid once.
class BillsView extends StatelessWidget {
  const BillsView({
    super.key,
    required this.states,
    required this.scheduleName,
    required this.onRecordPayment,
    required this.onLinkPayment,
    required this.onEditOccurrence,
  });

  final List<OccurrenceState> states;
  final String Function(String scheduleId) scheduleName;
  final ValueChanged<ScheduledOccurrence> onRecordPayment;
  final ValueChanged<ScheduledOccurrence> onLinkPayment;
  final ValueChanged<ScheduledOccurrence> onEditOccurrence;

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) {
      return const Center(child: Text('No bills or income scheduled'));
    }
    final sorted = [...states]
      ..sort((a, b) => a.occurrence.dueDate.compareTo(b.occurrence.dueDate));
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final state in sorted)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          scheduleName(state.occurrence.scheduleId),
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        '${state.occurrence.isEstimate ? 'about ' : ''}${formatMoney(state.expected)}',
                      ),
                    ],
                  ),
                  Text(
                    '${formatDate(state.occurrence.dueDate)} · '
                    '${occurrenceStatusLabels[state.status]}',
                  ),
                  if (state.paid.isPositive && !state.difference.isZero)
                    Text(
                      state.difference.isNegative
                          ? '${formatMoney(state.outstanding)} still to pay'
                          : 'Paid ${formatMoney(state.difference)} more than expected',
                    ),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    children: [
                      if (state.status != OccurrenceStatus.paid &&
                          state.status != OccurrenceStatus.skipped) ...[
                        TextButton(
                          onPressed: () => onLinkPayment(state.occurrence),
                          child: const Text('Link transaction'),
                        ),
                        TextButton(
                          onPressed: () => onRecordPayment(state.occurrence),
                          child: const Text('Record payment'),
                        ),
                      ],
                      TextButton(
                        onPressed: () => onEditOccurrence(state.occurrence),
                        child: const Text('Edit'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Month grid showing which days have scheduled items; the list above is
/// the accessible equivalent and the in-app calendar is authoritative.
class BillsCalendar extends StatelessWidget {
  const BillsCalendar({
    super.key,
    required this.month,
    required this.states,
    required this.onSelectDay,
  });

  final LocalDate month;
  final List<OccurrenceState> states;
  final ValueChanged<LocalDate> onSelectDay;

  @override
  Widget build(BuildContext context) {
    final first = LocalDate(month.year, month.month, 1);
    final days = LocalDate.daysInMonth(month.year, month.month);
    final leading = first.weekday - 1;
    final byDay = <int, int>{};
    for (final s in states) {
      final due = s.occurrence.dueDate;
      if (due.year == month.year && due.month == month.month) {
        byDay[due.day] = (byDay[due.day] ?? 0) + 1;
      }
    }
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final w in weekdays) Center(child: Text(w)),
        for (var i = 0; i < leading; i++) const SizedBox.shrink(),
        for (var day = 1; day <= days; day++)
          Semantics(
            button: true,
            label:
                '${formatDate(LocalDate(month.year, month.month, day))}'
                '${byDay[day] == null ? '' : ', ${byDay[day]} scheduled'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => onSelectDay(LocalDate(month.year, month.month, day)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$day'),
                  if (byDay[day] != null)
                    Text(
                      '•' * byDay[day]!.clamp(1, 3),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
