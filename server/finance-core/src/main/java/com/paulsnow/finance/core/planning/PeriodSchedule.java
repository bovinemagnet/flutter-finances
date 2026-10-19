package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Generates contiguous budget periods from an anchor date (BUD 02).
 * <p>
 * Each period starts on an occurrence of {@link #recurrence()} and ends the
 * day before the next one, so periods never overlap. Monthly periods keep the
 * anchor's day of month with the end-of-month rule (a month is never four
 * weeks); weeks and fortnights advance 7 and 14 days from the anchor; custom
 * periods advance {@code lengthDays} days.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class PeriodSchedule {

    private final PeriodCycle cycle;
    private final LocalDate anchor;
    private final Integer lengthDays;
    private final RolloverPolicy rollover;
    private final MonthEndRule monthEnd;
    private final Recurrence recurrence;

    /**
     * Creates a schedule.
     *
     * @param cycle      period length
     * @param anchor     start of period 0
     * @param lengthDays length of a custom period in days; ignored for other cycles
     * @param rollover   rollover policy for the plan, or null for none
     * @param monthEnd   end-of-month rule, or null for clamp
     * @throws IllegalArgumentException when a custom cycle has no positive
     *                                  length or the month-end rule does not
     *                                  suit the anchor
     */
    public PeriodSchedule(PeriodCycle cycle, LocalDate anchor, Integer lengthDays, RolloverPolicy rollover,
            MonthEndRule monthEnd) {
        this.cycle = Objects.requireNonNull(cycle, "cycle");
        this.anchor = Objects.requireNonNull(anchor, "anchor");
        this.lengthDays = lengthDays;
        this.rollover = rollover == null ? RolloverPolicy.NONE : rollover;
        this.monthEnd = monthEnd == null ? MonthEndRule.CLAMP : monthEnd;
        Frequency frequency = switch (cycle) {
            case MONTH -> Frequency.MONTHLY;
            case WEEK -> Frequency.WEEKLY;
            case FORTNIGHT -> Frequency.FORTNIGHTLY;
            case CUSTOM -> Frequency.DAILY;
        };
        this.recurrence = Recurrence.builder(frequency, anchor)
                .interval(cycle == PeriodCycle.CUSTOM ? customLength(lengthDays) : 1)
                .monthEnd(this.monthEnd)
                .build();
    }

    /**
     * Creates a schedule with no rollover and the clamp rule.
     *
     * @param cycle      period length
     * @param anchor     start of period 0
     * @param lengthDays length of a custom period in days; ignored for other cycles
     */
    public PeriodSchedule(PeriodCycle cycle, LocalDate anchor, Integer lengthDays) {
        this(cycle, anchor, lengthDays, RolloverPolicy.NONE, MonthEndRule.CLAMP);
    }

    private static int customLength(Integer lengthDays) {
        if (lengthDays == null || lengthDays < 1) {
            throw new IllegalArgumentException("custom periods need a positive length");
        }
        return lengthDays;
    }

    public PeriodCycle cycle() {
        return cycle;
    }

    public LocalDate anchor() {
        return anchor;
    }

    /** Returns the custom length in days, or null. */
    public Integer lengthDays() {
        return lengthDays;
    }

    public RolloverPolicy rollover() {
        return rollover;
    }

    public MonthEndRule monthEnd() {
        return monthEnd;
    }

    /** Returns the series of period start dates. */
    public Recurrence recurrence() {
        return recurrence;
    }

    /**
     * Returns period number {@code index}, where period 0 starts on the
     * anchor. Negative indexes are periods before the anchor.
     *
     * @param index period index
     * @return the period
     */
    public BudgetPeriod periodAt(long index) {
        return new BudgetPeriod(recurrence.occurrence(index), recurrence.occurrence(index + 1).minusDays(1),
                rollover);
    }

    /**
     * Returns the index of the period containing {@code date}.
     *
     * @param date the date
     * @return the period index, negative before the anchor
     */
    public long indexOf(LocalDate date) {
        return recurrence.indexOnOrBefore(date);
    }

    /**
     * Returns the period containing {@code date}.
     *
     * @param date the date
     * @return the period
     */
    public BudgetPeriod periodContaining(LocalDate date) {
        return periodAt(indexOf(date));
    }

    /**
     * Returns the period after {@code period}.
     *
     * @param period a period of this schedule
     * @return the next period
     */
    public BudgetPeriod next(BudgetPeriod period) {
        return periodAt(indexOf(period.start()) + 1);
    }

    /**
     * Returns the period before {@code period}.
     *
     * @param period a period of this schedule
     * @return the previous period
     */
    public BudgetPeriod previous(BudgetPeriod period) {
        return periodAt(indexOf(period.start()) - 1);
    }

    /**
     * Returns {@code count} consecutive periods starting with the anchor
     * period.
     *
     * @param count number of periods
     * @return the periods in order
     */
    public List<BudgetPeriod> generate(int count) {
        List<BudgetPeriod> periods = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            periods.add(periodAt(i));
        }
        return periods;
    }

    /**
     * Returns the monthly equivalent of an amount budgeted per period; an
     * estimate for anything other than monthly periods.
     *
     * @param perPeriod amount per period
     * @return the monthly equivalent
     */
    public MonthlyEstimate monthlyEquivalent(Money perPeriod) {
        return MonthlyEstimate.of(perPeriod, recurrence.frequency(), recurrence.interval());
    }
}
