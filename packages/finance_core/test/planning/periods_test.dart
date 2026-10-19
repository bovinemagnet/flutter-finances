import 'package:finance_core/finance_core.dart';
import 'package:test/test.dart';

void main() {
  LocalDate d(String text) => LocalDate.parse(text);
  const aud = Currency.aud;

  group('scaleHalfUp', () {
    test('rounds half away from zero', () {
      expect(scaleHalfUp(5, 1, 2), 3);
      expect(scaleHalfUp(-5, 1, 2), -3);
      expect(scaleHalfUp(4, 1, 3), 1);
      expect(scaleHalfUp(-4, 1, 3), -1);
    });

    test('does not overflow on large products', () {
      expect(scaleHalfUp(999999999999999, 10000, 10000), 999999999999999);
    });
  });

  group('Recurrence', () {
    test('monthly from 31 January preserves the intended day (A14)', () {
      final rule = Recurrence(
        frequency: Frequency.monthly,
        start: d('2027-01-31'),
      );
      expect(rule.datesBetween(d('2027-01-01'), d('2027-05-31')), [
        d('2027-01-31'),
        d('2027-02-28'),
        d('2027-03-31'),
        d('2027-04-30'),
        d('2027-05-31'),
      ]);
    });

    test('monthly from 31 January in a leap year uses 29 February', () {
      final rule = Recurrence(
        frequency: Frequency.monthly,
        start: d('2028-01-31'),
      );
      expect(rule.occurrence(1), d('2028-02-29'));
      expect(rule.occurrence(2), d('2028-03-31'));
    });

    test('an explicit intended day survives a start on a clamped date', () {
      final rule = Recurrence(
        frequency: Frequency.monthly,
        start: d('2027-02-28'),
        dayOfMonth: 31,
      );
      expect(rule.occurrence(0), d('2027-02-28'));
      expect(rule.occurrence(1), d('2027-03-31'));
      expect(
        () => Recurrence(
          frequency: Frequency.monthly,
          start: d('2027-03-28'),
          dayOfMonth: 31,
        ),
        throwsArgumentError,
      );
    });

    test('last-day rule keeps month ends', () {
      final rule = Recurrence(
        frequency: Frequency.monthly,
        start: d('2026-04-30'),
        monthEnd: MonthEndRule.lastDay,
      );
      expect(rule.occurrence(1), d('2026-05-31'));
      expect(rule.occurrence(2), d('2026-06-30'));
    });

    test('last-day rule requires a month-end start', () {
      expect(
        () => Recurrence(
          frequency: Frequency.monthly,
          start: d('2026-04-15'),
          monthEnd: MonthEndRule.lastDay,
        ),
        throwsArgumentError,
      );
    });

    test('fortnightly advances by fourteen days', () {
      final rule = Recurrence(
        frequency: Frequency.fortnightly,
        start: d('2026-07-02'),
        count: 3,
      );
      expect(rule.dates(), [d('2026-07-02'), d('2026-07-16'), d('2026-07-30')]);
    });

    test('quarterly and annual from 29 February clamp then recover', () {
      final annual = Recurrence(
        frequency: Frequency.annually,
        start: d('2028-02-29'),
        count: 5,
      );
      expect(annual.dates(), [
        d('2028-02-29'),
        d('2029-02-28'),
        d('2030-02-28'),
        d('2031-02-28'),
        d('2032-02-29'),
      ]);
      final quarterly = Recurrence(
        frequency: Frequency.quarterly,
        start: d('2026-11-30'),
        count: 2,
      );
      expect(quarterly.dates(), [d('2026-11-30'), d('2027-02-28')]);
    });

    test('custom interval and until bound', () {
      final rule = Recurrence(
        frequency: Frequency.daily,
        interval: 10,
        start: d('2026-07-01'),
        until: d('2026-07-31'),
      );
      expect(rule.dates(), [
        d('2026-07-01'),
        d('2026-07-11'),
        d('2026-07-21'),
        d('2026-07-31'),
      ]);
    });

    test('count and until stop at whichever comes first', () {
      final rule = Recurrence(
        frequency: Frequency.weekly,
        start: d('2026-07-01'),
        until: d('2026-07-20'),
        count: 10,
      );
      expect(rule.dates(), hasLength(3));
    });

    test('unbounded rule refuses to list every date', () {
      final rule = Recurrence(
        frequency: Frequency.weekly,
        start: d('2026-07-01'),
      );
      expect(rule.dates, throwsStateError);
    });

    test('index on or before a date', () {
      final rule = Recurrence(
        frequency: Frequency.monthly,
        start: d('2027-01-31'),
      );
      expect(rule.indexOnOrBefore(d('2027-02-27')), 0);
      expect(rule.indexOnOrBefore(d('2027-02-28')), 1);
      expect(rule.indexOnOrBefore(d('2027-01-30')), -1);
      final weekly = Recurrence(
        frequency: Frequency.weekly,
        start: d('2026-07-01'),
      );
      expect(weekly.indexOnOrBefore(d('2026-06-30')), -1);
      expect(weekly.indexOnOrBefore(d('2026-07-08')), 1);
    });
  });

  group('PeriodSchedule', () {
    test('calendar months from the first', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2026-07-01'),
        timezone: 'Australia/Sydney',
      );
      final periods = schedule.generate(3);
      expect(periods.map((p) => '${p.start}..${p.end}'), [
        '2026-07-01..2026-07-31',
        '2026-08-01..2026-08-31',
        '2026-09-01..2026-09-30',
      ]);
      expect(periods.first.timezone, 'Australia/Sydney');
      expect(periods.first.rollover, RolloverPolicy.none);
    });

    test('monthly from 31 January spans February without drift (A14)', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.month,
        anchor: d('2027-01-31'),
        timezone: 'Australia/Sydney',
      );
      final periods = schedule.generate(3);
      expect(periods.map((p) => '${p.start}..${p.end}'), [
        '2027-01-31..2027-02-27',
        '2027-02-28..2027-03-30',
        '2027-03-31..2027-04-29',
      ]);
    });

    test('fortnights from an anchor, including before it', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.fortnight,
        anchor: d('2026-07-02'),
        timezone: 'Australia/Sydney',
        rollover: RolloverPolicy.signed,
      );
      final period = schedule.periodContaining(d('2026-06-30'));
      expect(period.start, d('2026-06-18'));
      expect(period.end, d('2026-07-01'));
      expect(period.lengthDays, 14);
      expect(period.rollover, RolloverPolicy.signed);
      expect(schedule.next(period).start, d('2026-07-02'));
      expect(schedule.previous(period).start, d('2026-06-04'));
    });

    test('custom anchored periods of N days', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.custom,
        anchor: d('2026-07-01'),
        lengthDays: 10,
        timezone: 'UTC',
      );
      expect(schedule.generate(2).last.start, d('2026-07-11'));
      expect(schedule.generate(2).last.end, d('2026-07-20'));
      expect(
        () => PeriodSchedule(
          cycle: PeriodCycle.custom,
          anchor: d('2026-07-01'),
          timezone: 'UTC',
        ),
        throwsArgumentError,
      );
    });

    test('weekly periods contain their dates', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.week,
        anchor: d('2026-07-06'),
        timezone: 'UTC',
      );
      final period = schedule.periodContaining(d('2026-07-12'));
      expect(period.contains(d('2026-07-06')), isTrue);
      expect(period.contains(d('2026-07-12')), isTrue);
      expect(period.contains(d('2026-07-13')), isFalse);
    });
  });

  group('monthly equivalents', () {
    test('weekly uses 52/12 and is labelled an estimate', () {
      final estimate = monthlyEquivalent(Money(10000, aud), Frequency.weekly);
      expect(estimate.amount, Money(43333, aud));
      expect(estimate.isEstimate, isTrue);
      expect(estimate.annualFactor, '52/12');
    });

    test('fortnightly uses 26/12 with half-up rounding', () {
      expect(
        monthlyEquivalent(Money(100001, aud), Frequency.fortnightly).amount,
        Money(216669, aud),
      );
    });

    test('monthly is exact, quarterly and annual divide', () {
      final monthly = monthlyEquivalent(Money(5000, aud), Frequency.monthly);
      expect(monthly.amount, Money(5000, aud));
      expect(monthly.isEstimate, isFalse);
      expect(
        monthlyEquivalent(Money(30000, aud), Frequency.quarterly).amount,
        Money(10000, aud),
      );
      expect(
        monthlyEquivalent(Money(120000, aud), Frequency.annually).amount,
        Money(10000, aud),
      );
    });

    test('custom day intervals use 365 days a year', () {
      final estimate = monthlyEquivalent(
        Money(1000, aud),
        Frequency.daily,
        interval: 10,
      );
      expect(estimate.amount, Money(3042, aud));
      expect(estimate.annualFactor, '365/120');
    });

    test('period schedules expose the same factors', () {
      final schedule = PeriodSchedule(
        cycle: PeriodCycle.fortnight,
        anchor: d('2026-07-02'),
        timezone: 'UTC',
      );
      expect(schedule.recurrence.frequency, Frequency.fortnightly);
      expect(
        schedule.monthlyEquivalent(Money(1200, aud)).amount,
        Money(2600, aud),
      );
    });
  });
}
