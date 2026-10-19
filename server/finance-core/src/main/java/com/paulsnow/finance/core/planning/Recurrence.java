package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.time.YearMonth;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * A repeating series of local dates (PLAN 01, BUD 02).
 * <p>
 * Occurrence {@code n} is computed directly from {@link #start()}, never from
 * the previous occurrence, so clamping in a short month cannot make later
 * dates drift.
 *
 * @param frequency  repeat unit
 * @param start      first occurrence
 * @param interval   number of {@code frequency} units between occurrences, at least 1
 * @param until      last date an occurrence may fall on (inclusive), or null
 * @param count      maximum number of occurrences, or null
 * @param monthEnd   end-of-month rule for month-based repeats
 * @param dayOfMonth intended day of month for month-based repeats with the
 *                   clamp rule; a series continued from a clamped date (28
 *                   February for a 31st) keeps 31 so later dates do not drift
 * @author Paul Snow
 * @since 0.0.0
 */
public record Recurrence(Frequency frequency, LocalDate start, int interval, LocalDate until, Integer count,
        MonthEndRule monthEnd, int dayOfMonth) {

    /**
     * Validates the rule.
     *
     * @throws IllegalArgumentException when the interval is below 1, the
     *                                  count is negative, {@code lastDay} is
     *                                  used without a month-based frequency
     *                                  starting on a month end, or the start
     *                                  is not the clamped {@code dayOfMonth}
     */
    public Recurrence {
        Objects.requireNonNull(frequency, "frequency");
        Objects.requireNonNull(start, "start");
        monthEnd = monthEnd == null ? MonthEndRule.CLAMP : monthEnd;
        if (interval < 1) {
            throw new IllegalArgumentException("interval must be at least 1");
        }
        if (count != null && count < 0) {
            throw new IllegalArgumentException("count must not be negative");
        }
        if (monthEnd == MonthEndRule.LAST_DAY
                && (!frequency.isMonthBased() || start.getDayOfMonth() != start.lengthOfMonth())) {
            throw new IllegalArgumentException(
                    "The last-day rule needs a month-based frequency starting on a month end");
        }
        if (dayOfMonth < 1 || dayOfMonth > 31 || (frequency.isMonthBased() && monthEnd == MonthEndRule.CLAMP
                && !addMonths(start, 0, dayOfMonth).equals(start))) {
            throw new IllegalArgumentException(
                    "The start must be the intended day " + dayOfMonth + ", clamped to its month");
        }
    }

    /**
     * Starts a rule repeating every {@code frequency} unit from {@code start},
     * unbounded, with the clamp rule and the start's day of month.
     *
     * @param frequency repeat unit
     * @param start     first occurrence
     * @return a builder
     */
    public static Builder builder(Frequency frequency, LocalDate start) {
        return new Builder(frequency, start);
    }

    /** Returns whether the series ends, through {@code until} or {@code count}. */
    public boolean isBounded() {
        return until != null || count != null;
    }

    /**
     * Returns the unbounded {@code n}th date of the series. {@code n} may be
     * negative to step backwards from {@link #start()} (used for budget
     * periods before an anchor).
     *
     * @param n occurrence index
     * @return the date
     */
    public LocalDate occurrence(long n) {
        if (!frequency.isMonthBased()) {
            return start.plusDays(Math.multiplyExact(n, (long) interval * frequency.days()));
        }
        long months = Math.multiplyExact(n, (long) interval * frequency.months());
        if (monthEnd == MonthEndRule.LAST_DAY) {
            return YearMonth.from(start).plusMonths(months).atEndOfMonth();
        }
        return addMonths(start, months, dayOfMonth);
    }

    /**
     * Returns the index of the last unbounded occurrence on or before
     * {@code date}; negative when {@code date} is before {@link #start()}.
     *
     * @param date the date
     * @return the occurrence index
     */
    public long indexOnOrBefore(LocalDate date) {
        if (!frequency.isMonthBased()) {
            long step = (long) interval * frequency.days();
            return Math.floorDiv(ChronoUnit.DAYS.between(start, date), step);
        }
        long monthsApart = ChronoUnit.MONTHS.between(YearMonth.from(start), YearMonth.from(date));
        long index = Math.floorDiv(monthsApart, (long) interval * frequency.months());
        while (occurrence(index).isAfter(date)) {
            index--;
        }
        while (!occurrence(index + 1).isAfter(date)) {
            index++;
        }
        return index;
    }

    /**
     * Returns whether {@code date} is an occurrence of this series within its
     * bounds.
     *
     * @param date the date
     * @return true for an occurrence
     */
    public boolean isOccurrence(LocalDate date) {
        long n = indexOnOrBefore(date);
        return occurrence(n).equals(date) && inBounds(n, date);
    }

    /**
     * Returns the occurrences within {@code from}..{@code to} inclusive,
     * honouring {@code until} and {@code count}.
     *
     * @param from first date
     * @param to   last date
     * @return the dates in order
     */
    public List<LocalDate> datesBetween(LocalDate from, LocalDate to) {
        List<LocalDate> result = new ArrayList<>();
        long first = indexOnOrBefore(from);
        for (long n = Math.max(first, 0);; n++) {
            LocalDate date = occurrence(n);
            if (date.isAfter(to) || !inBounds(n, date)) {
                break;
            }
            if (!date.isBefore(from)) {
                result.add(date);
            }
        }
        return result;
    }

    /**
     * Returns every occurrence of a bounded series.
     *
     * @return the dates in order
     * @throws IllegalStateException when the series is unbounded
     */
    public List<LocalDate> dates() {
        if (!isBounded()) {
            throw new IllegalStateException("An unbounded series has no end");
        }
        List<LocalDate> result = new ArrayList<>();
        for (long n = 0;; n++) {
            LocalDate date = occurrence(n);
            if (!inBounds(n, date)) {
                break;
            }
            result.add(date);
        }
        return result;
    }

    private boolean inBounds(long n, LocalDate date) {
        return n >= 0 && (count == null || n < count) && (until == null || !date.isAfter(until));
    }

    /**
     * Moves {@code date} by whole months, using {@code intendedDay} or the
     * last day of a shorter target month.
     */
    static LocalDate addMonths(LocalDate date, long months, int intendedDay) {
        YearMonth target = YearMonth.from(date).plusMonths(months);
        return target.atDay(Math.min(intendedDay, target.lengthOfMonth()));
    }

    /**
     * Builder for {@link Recurrence}.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final Frequency frequency;
        private final LocalDate start;
        private int interval = 1;
        private LocalDate until;
        private Integer count;
        private MonthEndRule monthEnd = MonthEndRule.CLAMP;
        private Integer dayOfMonth;

        private Builder(Frequency frequency, LocalDate start) {
            this.frequency = frequency;
            this.start = start;
        }

        public Builder interval(int value) {
            this.interval = value;
            return this;
        }

        public Builder until(LocalDate value) {
            this.until = value;
            return this;
        }

        public Builder count(Integer value) {
            this.count = value;
            return this;
        }

        public Builder monthEnd(MonthEndRule value) {
            this.monthEnd = value;
            return this;
        }

        /** Sets the intended day of month; null means the start's day. */
        public Builder dayOfMonth(Integer value) {
            this.dayOfMonth = value;
            return this;
        }

        /**
         * Builds the rule.
         *
         * @return the recurrence
         * @throws IllegalArgumentException when the rule is invalid
         */
        public Recurrence build() {
            return new Recurrence(frequency, start, interval, until, count, monthEnd,
                    dayOfMonth != null ? dayOfMonth : start.getDayOfMonth());
        }
    }
}
