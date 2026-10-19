package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.money.Money;

/**
 * Payment state of one scheduled occurrence (PLAN 02).
 *
 * @param occurrence the occurrence
 * @param status     its status
 * @param paid       total of counted payment links
 * @param payments   the counted payment links
 * @author Paul Snow
 * @since 0.0.0
 */
public record OccurrenceState(ScheduledOccurrence occurrence, OccurrenceStatus status, Money paid,
        List<OccurrencePayment> payments) {

    public OccurrenceState {
        Objects.requireNonNull(occurrence, "occurrence");
        Objects.requireNonNull(status, "status");
        Objects.requireNonNull(paid, "paid");
        payments = List.copyOf(payments);
    }

    /**
     * Works out an occurrence's status. Links count only when their journal
     * is posted or pending; drafts, reversed and unknown journals are
     * ignored. The occurrence is paid when {@code paid ≥ amount} or any
     * counted link settles it.
     *
     * @param occurrence      the occurrence
     * @param payments        payment links of any occurrence
     * @param journalStatuses status of each known journal by identifier
     * @param today           the workspace's local date
     * @param accountDataAsOf date the paying account's data is complete to,
     *                        or null; without it a missed date is
     *                        {@link OccurrenceStatus#UNKNOWN}
     * @return the state
     */
    public static OccurrenceState assess(ScheduledOccurrence occurrence, Iterable<OccurrencePayment> payments,
            Map<String, JournalStatus> journalStatuses, LocalDate today, LocalDate accountDataAsOf) {
        List<OccurrencePayment> counted = new ArrayList<>();
        Money paid = Money.zero(occurrence.amount().currency());
        boolean settles = false;
        for (OccurrencePayment p : payments) {
            JournalStatus journal = journalStatuses.get(p.journalId());
            if (p.scheduleId().equals(occurrence.scheduleId())
                    && p.occurrenceDate().equals(occurrence.originalDate())
                    && (journal == JournalStatus.POSTED || journal == JournalStatus.PENDING)) {
                counted.add(p);
                paid = paid.plus(p.amount());
                settles |= p.settles();
            }
        }
        LocalDate due = occurrence.dueDate();
        OccurrenceStatus status;
        if (occurrence.skipped()) {
            status = OccurrenceStatus.SKIPPED;
        } else if (paid.compareTo(occurrence.amount()) >= 0 || settles) {
            status = OccurrenceStatus.PAID;
        } else if (paid.isPositive()) {
            status = OccurrenceStatus.PARTIALLY_PAID;
        } else if (due.isAfter(today)) {
            status = OccurrenceStatus.UPCOMING;
        } else if (due.equals(today)) {
            status = OccurrenceStatus.DUE;
        } else if (accountDataAsOf != null && !accountDataAsOf.isBefore(due)) {
            status = OccurrenceStatus.UNPAID;
        } else {
            status = OccurrenceStatus.UNKNOWN;
        }
        return new OccurrenceState(occurrence, status, paid, counted);
    }

    /** Returns the expected amount. */
    public Money expected() {
        return occurrence.amount();
    }

    /** Returns paid less expected; non-zero shows a changed amount. */
    public Money difference() {
        return paid.minus(expected());
    }

    /** Returns the amount still expected; zero once paid, settled or skipped. */
    public Money outstanding() {
        Money zero = Money.zero(expected().currency());
        if (status == OccurrenceStatus.PAID || status == OccurrenceStatus.SKIPPED) {
            return zero;
        }
        Money left = expected().minus(paid);
        return left.isNegative() ? zero : left;
    }

    /** Returns the identifiers of the counted journals. */
    public List<String> journalIds() {
        return payments.stream().map(OccurrencePayment::journalId).toList();
    }
}
