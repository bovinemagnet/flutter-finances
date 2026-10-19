package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.Objects;

/**
 * One budget period. Both ends are inclusive.
 *
 * @param start    first day
 * @param end      last day
 * @param rollover how remaining amounts carry into the next period
 * @author Paul Snow
 * @since 0.0.0
 */
public record BudgetPeriod(LocalDate start, LocalDate end, RolloverPolicy rollover) {

    public BudgetPeriod {
        Objects.requireNonNull(start, "start");
        Objects.requireNonNull(end, "end");
        rollover = rollover == null ? RolloverPolicy.NONE : rollover;
        if (end.isBefore(start)) {
            throw new IllegalArgumentException("Period ends before it starts");
        }
    }

    /** Returns the number of days in the period. */
    public long lengthDays() {
        return ChronoUnit.DAYS.between(start, end) + 1;
    }

    /**
     * Returns whether {@code date} falls inside the period.
     *
     * @param date the date
     * @return true when within start and end inclusive
     */
    public boolean contains(LocalDate date) {
        return !date.isBefore(start) && !date.isAfter(end);
    }

    @Override
    public String toString() {
        return start + ".." + end;
    }
}
