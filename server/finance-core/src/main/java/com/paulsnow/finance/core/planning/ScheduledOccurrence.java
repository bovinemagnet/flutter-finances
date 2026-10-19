package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * One expected occurrence of a schedule. It is a plan, not a transaction.
 *
 * @param scheduleId   the schedule
 * @param originalDate the occurrence's date in the series
 * @param dueDate      when it is due, after any override
 * @param amount       expected amount, after any override
 * @param isEstimate   whether the amount is an estimate
 * @param skipped      whether a "this occurrence" edit skipped it
 * @param overrideId   the override applied, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record ScheduledOccurrence(String scheduleId, LocalDate originalDate, LocalDate dueDate, Money amount,
        boolean isEstimate, boolean skipped, String overrideId) {

    public ScheduledOccurrence {
        Objects.requireNonNull(scheduleId, "scheduleId");
        Objects.requireNonNull(originalDate, "originalDate");
        Objects.requireNonNull(dueDate, "dueDate");
        Objects.requireNonNull(amount, "amount");
    }

    /** Returns the stable identifier: schedule id and original date. */
    public String key() {
        return scheduleId + "@" + originalDate;
    }
}
