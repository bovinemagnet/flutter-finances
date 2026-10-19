import 'package:finance_app/features/plan/bills_view.dart';
import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_AU'));
  const aud = Currency.aud;
  final today = LocalDate(2026, 10, 19);
  final rent = RecurringSchedule(
    id: 'rent',
    name: 'Rent',
    kind: ScheduleKind.expense,
    recurrence: Recurrence(
      frequency: Frequency.fortnightly,
      start: LocalDate(2026, 10, 12),
    ),
    amount: Money(90000, aud),
    accountId: 'bank',
    categoryId: 'rent',
  );
  final occurrences = rent.occurrencesBetween(
    LocalDate(2026, 10, 1),
    LocalDate(2026, 10, 31),
  );
  final states = [
    assessOccurrence(
      occurrences[0],
      payments: [
        OccurrencePayment(
          id: 'p1',
          scheduleId: 'rent',
          occurrenceDate: occurrences[0].originalDate,
          journalId: 'j1',
          amount: Money(50000, aud),
        ),
      ],
      journalStatuses: const {'j1': JournalStatus.posted},
      today: today,
    ),
    assessOccurrence(occurrences[1], journalStatuses: const {}, today: today),
  ];

  testWidgets('shows partial payment and offers link or record actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorded = <ScheduledOccurrence>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: BillsView(
                  states: states,
                  scheduleName: (_) => 'Rent',
                  onRecordPayment: recorded.add,
                  onLinkPayment: (_) {},
                  onEditOccurrence: (_) {},
                ),
              ),
              BillsCalendar(month: today, states: states, onSelectDay: (_) {}),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('Partly paid'), findsOneWidget);
    expect(find.text(r'$400.00 still to pay'), findsOneWidget);
    expect(find.textContaining('Upcoming'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('26 Oct 2026, 1 scheduled')),
      findsOneWidget,
    );
    await tester.tap(find.text('Record payment').last);
    expect(recorded.single.dueDate, LocalDate(2026, 10, 26));
  });
}
