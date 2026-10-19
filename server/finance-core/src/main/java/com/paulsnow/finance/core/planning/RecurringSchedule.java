package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import com.paulsnow.finance.core.money.Money;

/**
 * A recurring bill, income or transfer (PLAN 01). Scheduling never posts a
 * transaction; occurrences only become actual history when linked to a
 * journal the user confirmed.
 *
 * @param id               identifier
 * @param name             display name
 * @param kind             what the schedule does to cash
 * @param recurrence       due dates; the start is the first due date
 * @param amount           expected positive magnitude of each occurrence
 * @param isEstimate       whether {@code amount} is an estimate, such as a variable utility bill
 * @param accountId        the account paid from, or paid into for income
 * @param counterAccountId the receiving account of a transfer, or null
 * @param categoryId       category, or null
 * @param confirmed        confirmed or user-accepted; only confirmed schedules
 *                         count in forecasts and the discretionary estimate
 * @author Paul Snow
 * @since 0.0.0
 */
public record RecurringSchedule(String id, String name, ScheduleKind kind, Recurrence recurrence, Money amount,
        boolean isEstimate, String accountId, String counterAccountId, String categoryId, boolean confirmed) {

    /**
     * Validates the schedule.
     *
     * @throws IllegalArgumentException when the amount is not positive or a
     *                                  transfer has no different counter account
     */
    public RecurringSchedule {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(recurrence, "recurrence");
        Objects.requireNonNull(amount, "amount");
        Objects.requireNonNull(accountId, "accountId");
        if (!amount.isPositive()) {
            throw new IllegalArgumentException("amount must be positive");
        }
        if (kind == ScheduleKind.TRANSFER && (counterAccountId == null || counterAccountId.equals(accountId))) {
            throw new IllegalArgumentException("A transfer needs a different counter account");
        }
    }

    /**
     * Returns a copy projected at a different amount.
     *
     * @param newAmount the amount
     * @return the copy
     */
    public RecurringSchedule withAmount(Money newAmount) {
        return new RecurringSchedule(id, name, kind, recurrence, newAmount, isEstimate, accountId, counterAccountId,
                categoryId, confirmed);
    }

    /**
     * Returns the occurrences due within {@code from}..{@code to} inclusive
     * after applying "this occurrence" {@code overrides}, ordered by due date
     * then original date. Skipped occurrences are included and flagged so
     * calendars can show them. Overrides for other schedules, or whose
     * original date is not an occurrence of this schedule, are ignored; a
     * moved occurrence appears where its new due date falls.
     *
     * @param from      first due date
     * @param to        last due date
     * @param overrides overrides of any schedule
     * @return the occurrences
     */
    public List<ScheduledOccurrence> occurrencesBetween(LocalDate from, LocalDate to,
            Iterable<OccurrenceOverride> overrides) {
        Map<LocalDate, OccurrenceOverride> byDate = new LinkedHashMap<>();
        for (OccurrenceOverride o : overrides) {
            if (o.scheduleId().equals(id) && recurrence.isOccurrence(o.originalDate())) {
                byDate.put(o.originalDate(), o);
            }
        }
        Set<LocalDate> originals = new LinkedHashSet<>(recurrence.datesBetween(from, to));
        for (OccurrenceOverride o : byDate.values()) {
            if (o.dueDate() != null && !o.dueDate().isBefore(from) && !o.dueDate().isAfter(to)) {
                originals.add(o.originalDate());
            }
        }
        List<ScheduledOccurrence> result = new ArrayList<>();
        for (LocalDate original : originals) {
            OccurrenceOverride edit = byDate.get(original);
            LocalDate due = edit != null && edit.dueDate() != null ? edit.dueDate() : original;
            Money expected = edit != null && edit.amount() != null ? edit.amount() : amount;
            boolean estimate = (edit == null || edit.amount() == null) && isEstimate;
            if (!due.isBefore(from) && !due.isAfter(to)) {
                result.add(new ScheduledOccurrence(id, original, due, expected, estimate,
                        edit != null && edit.skipped(), edit == null ? null : edit.id()));
            }
        }
        result.sort(Comparator.comparing(ScheduledOccurrence::dueDate)
                .thenComparing(ScheduledOccurrence::originalDate));
        return result;
    }

    /**
     * Starts a confirmed, non-estimate schedule.
     *
     * @param id         identifier
     * @param kind       what the schedule does to cash
     * @param recurrence due dates
     * @param amount     positive amount per occurrence
     * @param accountId  paying or receiving account
     * @return a builder
     */
    public static Builder builder(String id, ScheduleKind kind, Recurrence recurrence, Money amount,
            String accountId) {
        return new Builder(id, kind, recurrence, amount, accountId);
    }

    /**
     * Builder for {@link RecurringSchedule}.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final String id;
        private final ScheduleKind kind;
        private final Recurrence recurrence;
        private final Money amount;
        private final String accountId;
        private String name;
        private boolean isEstimate;
        private String counterAccountId;
        private String categoryId;
        private boolean confirmed = true;

        private Builder(String id, ScheduleKind kind, Recurrence recurrence, Money amount, String accountId) {
            this.id = id;
            this.kind = kind;
            this.recurrence = recurrence;
            this.amount = amount;
            this.accountId = accountId;
            this.name = id;
        }

        public Builder name(String value) {
            this.name = value;
            return this;
        }

        public Builder isEstimate(boolean value) {
            this.isEstimate = value;
            return this;
        }

        public Builder counterAccountId(String value) {
            this.counterAccountId = value;
            return this;
        }

        public Builder categoryId(String value) {
            this.categoryId = value;
            return this;
        }

        public Builder confirmed(boolean value) {
            this.confirmed = value;
            return this;
        }

        public RecurringSchedule build() {
            return new RecurringSchedule(id, name, kind, recurrence, amount, isEstimate, accountId, counterAccountId,
                    categoryId, confirmed);
        }
    }
}
