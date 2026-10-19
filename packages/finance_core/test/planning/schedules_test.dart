import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  const aud = Currency.aud;
  Money m(String text) => Money.parse(text, aud);
  LocalDate d(String text) => LocalDate.parse(text);

  RecurringSchedule rent({int? count}) => RecurringSchedule(
    id: 'rent',
    name: 'Rent',
    kind: ScheduleKind.expense,
    recurrence: Recurrence(
      frequency: Frequency.monthly,
      start: d('2027-01-31'),
      count: count,
    ),
    amount: m('2000.00'),
    accountId: 'bank',
    categoryId: 'housing',
  );

  group('occurrences (PLAN 01, A14)', () {
    test('monthly from 31 January spans February consistently', () {
      final dates = rent()
          .occurrencesBetween(d('2027-01-01'), d('2027-04-30'))
          .map((o) => o.dueDate);
      expect(dates, [
        d('2027-01-31'),
        d('2027-02-28'),
        d('2027-03-31'),
        d('2027-04-30'),
      ]);
    });

    test('scheduling alone never posts a transaction', () {
      final schedule = rent();
      final occurrences = schedule.occurrencesBetween(
        d('2027-01-01'),
        d('2027-12-31'),
      );
      expect(occurrences, hasLength(12));
      expect(occurrences.first, isA<ScheduledOccurrence>());
      expect(occurrences.first.amount, m('2000.00'));
    });

    test('this occurrence: move, change amount or skip', () {
      final overrides = [
        OccurrenceOverride(
          id: 'o1',
          scheduleId: 'rent',
          originalDate: d('2027-02-28'),
          dueDate: d('2027-03-01'),
          amount: m('2100.00'),
        ),
        OccurrenceOverride(
          id: 'o2',
          scheduleId: 'rent',
          originalDate: d('2027-03-31'),
          skipped: true,
        ),
        OccurrenceOverride(
          id: 'o3',
          scheduleId: 'rent',
          originalDate: d('2027-04-30'),
          dueDate: d('2027-05-02'),
        ),
        OccurrenceOverride(
          id: 'ignored',
          scheduleId: 'rent',
          originalDate: d('2027-04-15'),
          amount: m('1.00'),
        ),
      ];
      final occurrences = rent().occurrencesBetween(
        d('2027-02-01'),
        d('2027-04-30'),
        overrides: overrides,
      );
      expect(occurrences.map((o) => o.dueDate), [
        d('2027-03-01'),
        d('2027-03-31'),
      ]);
      expect(occurrences.first.originalDate, d('2027-02-28'));
      expect(occurrences.first.amount, m('2100.00'));
      expect(occurrences.first.overrideId, 'o1');
      expect(occurrences.last.skipped, isTrue);
    });

    test('this and future splits the series without drift', () {
      final split = rent(count: 12).splitFrom(
        d('2027-02-28'),
        newId: 'rent-2',
        edit: (s) => s.copyWith(amount: m('2100.00')),
      );
      expect(split.ended.recurrence.until, d('2027-02-27'));
      expect(split.ended.recurrence.count, 1);
      expect(split.continued.id, 'rent-2');
      expect(split.continued.previousScheduleId, 'rent');
      expect(split.continued.recurrence.count, 11);
      final continued = split.continued.occurrencesBetween(
        d('2027-01-01'),
        d('2027-04-30'),
      );
      expect(continued.map((o) => o.dueDate), [
        d('2027-02-28'),
        d('2027-03-31'),
        d('2027-04-30'),
      ]);
      expect(continued.first.amount, m('2100.00'));
      expect(
        split.ended
            .occurrencesBetween(d('2027-01-01'), d('2027-12-31'))
            .map((o) => o.dueDate),
        [d('2027-01-31')],
      );
    });

    test('a split must start on an occurrence', () {
      expect(
        () => rent().splitFrom(d('2027-02-15'), newId: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('payments (PLAN 02, A13)', () {
    final occurrence = rent()
        .occurrencesBetween(d('2027-01-31'), d('2027-01-31'))
        .single;
    final statuses = {
      'j1': JournalStatus.posted,
      'j2': JournalStatus.posted,
      'draft': JournalStatus.draft,
    };

    OccurrencePayment payment(
      String id,
      String journal,
      String amount, {
      bool settles = false,
    }) => OccurrencePayment(
      id: id,
      scheduleId: 'rent',
      occurrenceDate: d('2027-01-31'),
      journalId: journal,
      amount: m(amount),
      settles: settles,
    );

    test('linked to its actual journal it is paid', () {
      final state = assessOccurrence(
        occurrence,
        payments: [payment('p1', 'j1', '2000.00')],
        journalStatuses: statuses,
        today: d('2027-02-10'),
      );
      expect(state.status, OccurrenceStatus.paid);
      expect(state.outstanding, m('0.00'));
      expect(state.journalIds, ['j1']);
    });

    test('partial payments and changed amounts stay visible', () {
      final partial = assessOccurrence(
        occurrence,
        payments: [payment('p1', 'j1', '1500.00')],
        journalStatuses: statuses,
        today: d('2027-02-10'),
      );
      expect(partial.status, OccurrenceStatus.partiallyPaid);
      expect(partial.outstanding, m('500.00'));
      final changed = assessOccurrence(
        occurrence,
        payments: [payment('p1', 'j1', '1950.00', settles: true)],
        journalStatuses: statuses,
        today: d('2027-02-10'),
      );
      expect(changed.status, OccurrenceStatus.paid);
      expect(changed.difference, m('-50.00'));
      expect(changed.outstanding, m('0.00'));
    });

    test('links to drafts or missing journals do not count', () {
      final state = assessOccurrence(
        occurrence,
        payments: [payment('p1', 'draft', '2000.00')],
        journalStatuses: statuses,
        today: d('2027-01-20'),
      );
      expect(state.status, OccurrenceStatus.upcoming);
      expect(
        assessOccurrence(
          occurrence,
          journalStatuses: statuses,
          today: d('2027-01-31'),
        ).status,
        OccurrenceStatus.due,
      );
    });

    test('a missed date with stale account data is unknown, not unpaid', () {
      final stale = assessOccurrence(
        occurrence,
        journalStatuses: statuses,
        today: d('2027-02-10'),
        accountDataAsOf: d('2027-01-25'),
      );
      expect(stale.status, OccurrenceStatus.unknown);
      expect(
        assessOccurrence(
          occurrence,
          journalStatuses: statuses,
          today: d('2027-02-10'),
        ).status,
        OccurrenceStatus.unknown,
      );
      final fresh = assessOccurrence(
        occurrence,
        journalStatuses: statuses,
        today: d('2027-02-10'),
        accountDataAsOf: d('2027-02-09'),
      );
      expect(fresh.status, OccurrenceStatus.unpaid);
    });

    test('an occurrence is marked paid once and a journal pays one bill', () {
      var links = <OccurrencePayment>[];
      final paid = assessOccurrence(
        occurrence,
        payments: links,
        journalStatuses: statuses,
        today: d('2027-02-10'),
      );
      links = linkPayment(links, payment('p1', 'j1', '2000.00'), paid);
      final nowPaid = assessOccurrence(
        occurrence,
        payments: links,
        journalStatuses: statuses,
        today: d('2027-02-10'),
      );
      expect(
        () => linkPayment(links, payment('p2', 'j2', '1.00'), nowPaid),
        throwsStateError,
      );
      expect(
        () => linkPayment(
          links,
          OccurrencePayment(
            id: 'p3',
            scheduleId: 'other',
            occurrenceDate: d('2027-01-31'),
            journalId: 'j1',
            amount: m('1.00'),
          ),
          paid,
        ),
        throwsStateError,
      );
    });

    test('skipped occurrences report skipped', () {
      final skipped = rent()
          .occurrencesBetween(
            d('2027-01-31'),
            d('2027-01-31'),
            overrides: [
              OccurrenceOverride(
                id: 'o',
                scheduleId: 'rent',
                originalDate: d('2027-01-31'),
                skipped: true,
              ),
            ],
          )
          .single;
      expect(
        assessOccurrence(
          skipped,
          journalStatuses: statuses,
          today: d('2027-03-01'),
        ).status,
        OccurrenceStatus.skipped,
      );
    });
  });

  group('reminders (PLAN 04)', () {
    final occurrence = rent()
        .occurrencesBetween(d('2027-01-31'), d('2027-01-31'))
        .single;

    test('lead time and text hiding amounts and merchants by default', () {
      final schedule = rent().copyWith(
        reminder: const ReminderPreference(leadDays: 2, minuteOfDay: 9 * 60),
      );
      final reminder = planReminder(schedule, occurrence)!;
      expect(reminder.remindOn, d('2027-01-29'));
      expect(reminder.minuteOfDay, 540);
      expect(reminder.text, 'A scheduled payment is due on 2027-01-31');
      expect(reminder.text, isNot(contains('Rent')));
      expect(reminder.text, isNot(contains('2000')));
    });

    test('details only when the user opts in', () {
      final schedule = rent().copyWith(
        reminder: const ReminderPreference(showDetails: true),
      );
      expect(
        planReminder(schedule, occurrence)!.text,
        'Rent: 2000.00 AUD due on 2027-01-31',
      );
    });

    test('quiet hours move the reminder to their end', () {
      final overnight = rent().copyWith(
        reminder: const ReminderPreference(
          leadDays: 1,
          minuteOfDay: 23 * 60,
          quietStartMinute: 22 * 60,
          quietEndMinute: 7 * 60,
        ),
      );
      final moved = planReminder(overnight, occurrence)!;
      expect(moved.remindOn, d('2027-01-31'));
      expect(moved.minuteOfDay, 420);
      final early = rent().copyWith(
        reminder: const ReminderPreference(
          leadDays: 1,
          minuteOfDay: 6 * 60,
          quietStartMinute: 22 * 60,
          quietEndMinute: 7 * 60,
        ),
      );
      expect(planReminder(early, occurrence)!.remindOn, d('2027-01-30'));
      expect(planReminder(early, occurrence)!.minuteOfDay, 420);
      final lunch = rent().copyWith(
        reminder: const ReminderPreference(
          minuteOfDay: 12 * 60 + 30,
          quietStartMinute: 12 * 60,
          quietEndMinute: 13 * 60,
        ),
      );
      expect(planReminder(lunch, occurrence)!.minuteOfDay, 780);
    });

    test('disabled reminders and skipped occurrences produce none', () {
      final off = rent().copyWith(
        reminder: const ReminderPreference(enabled: false),
      );
      expect(planReminder(off, occurrence), isNull);
    });
  });
}
