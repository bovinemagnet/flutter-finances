package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * A "this occurrence" edit: move, change the amount, or skip.
 *
 * @param id           identifier
 * @param scheduleId   the schedule edited
 * @param originalDate the occurrence's date in the series, which identifies it
 * @param dueDate      new due date, or null to keep the original
 * @param amount       new amount, or null to keep the schedule amount
 * @param skipped      whether the occurrence is skipped
 * @author Paul Snow
 * @since 0.0.0
 */
public record OccurrenceOverride(String id, String scheduleId, LocalDate originalDate, LocalDate dueDate,
        Money amount, boolean skipped) {

    public OccurrenceOverride {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(scheduleId, "scheduleId");
        Objects.requireNonNull(originalDate, "originalDate");
    }
}
