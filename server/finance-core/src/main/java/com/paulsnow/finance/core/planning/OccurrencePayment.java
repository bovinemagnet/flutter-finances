package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Links an occurrence to the journal that actually paid (or received) it
 * (PLAN 02). Several links record partial payments.
 *
 * @param id             identifier
 * @param scheduleId     the schedule
 * @param occurrenceDate the occurrence's original date in its series
 * @param journalId      the paying journal
 * @param amount         amount paid by this link
 * @param settles        marks the occurrence paid even when the amount differs
 * @author Paul Snow
 * @since 0.0.0
 */
public record OccurrencePayment(String id, String scheduleId, LocalDate occurrenceDate, String journalId,
        Money amount, boolean settles) {

    public OccurrencePayment {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(scheduleId, "scheduleId");
        Objects.requireNonNull(occurrenceDate, "occurrenceDate");
        Objects.requireNonNull(journalId, "journalId");
        Objects.requireNonNull(amount, "amount");
    }
}
