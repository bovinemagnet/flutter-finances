package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * One hypothetical change in a {@link Scenario} (PLAN 03). Every forecast
 * line it produces or alters is tagged hypothetical.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public sealed interface ScenarioChange {

    /** Returns the change identifier. */
    String id();

    /**
     * A single hypothetical cash movement.
     *
     * @param id          identifier
     * @param date        when it happens
     * @param accountId   the account affected
     * @param amount      signed amount, negative for money leaving the account
     * @param description description, or null
     * @author Paul Snow
     * @since 0.0.0
     */
    record OneOff(String id, LocalDate date, String accountId, Money amount, String description)
            implements ScenarioChange {

        public OneOff {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(date, "date");
            Objects.requireNonNull(accountId, "accountId");
            Objects.requireNonNull(amount, "amount");
        }
    }

    /**
     * Projects a schedule's occurrences at a different amount. An occurrence
     * override's amount still wins.
     *
     * @param id         identifier
     * @param scheduleId the schedule
     * @param amount     the new positive amount
     * @author Paul Snow
     * @since 0.0.0
     */
    record ScheduleAmount(String id, String scheduleId, Money amount) implements ScenarioChange {

        public ScheduleAmount {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(scheduleId, "scheduleId");
            Objects.requireNonNull(amount, "amount");
        }
    }

    /**
     * Leaves a schedule out of the projection.
     *
     * @param id         identifier
     * @param scheduleId the schedule
     * @author Paul Snow
     * @since 0.0.0
     */
    record RemoveSchedule(String id, String scheduleId) implements ScenarioChange {

        public RemoveSchedule {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(scheduleId, "scheduleId");
        }
    }

    /**
     * Projects an additional schedule.
     *
     * @param id       identifier
     * @param schedule the schedule
     * @author Paul Snow
     * @since 0.0.0
     */
    record AddSchedule(String id, RecurringSchedule schedule) implements ScenarioChange {

        public AddSchedule {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(schedule, "schedule");
        }
    }
}
