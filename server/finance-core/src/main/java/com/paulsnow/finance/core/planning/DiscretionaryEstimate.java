package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.money.Money;

/**
 * The explainable discretionary spending estimate (BUD 07). Build one with
 * {@link #builder(LedgerProjection, LocalDate, LocalDate)}.
 *
 * @param budgetLimit            remaining discretionary budget after pending purchases and
 *                               unposted discretionary commitments; null when there is no budget
 * @param cashLimit              lowest projected eligible cash over the horizon less the buffer
 * @param discretionaryRemaining Σ remaining after pending of discretionary categories, or null
 * @param unpostedCommitments    outstanding discretionary schedule occurrences, or null
 * @param minimumBuffer          the buffer applied, zero when none was given
 * @param forecast               the cash forecast behind the cash limit
 * @param sourceFreshness        oldest "data complete to" date among eligible accounts, or null
 * @param missingInputs          inputs that are missing or stale; the result is incomplete if any
 * @author Paul Snow
 * @since 0.0.0
 */
public record DiscretionaryEstimate(Money budgetLimit, Money cashLimit, Money discretionaryRemaining,
        Money unpostedCommitments, Money minimumBuffer, CashForecast forecast, LocalDate sourceFreshness,
        List<String> missingInputs) {

    public DiscretionaryEstimate {
        Objects.requireNonNull(cashLimit, "cashLimit");
        Objects.requireNonNull(minimumBuffer, "minimumBuffer");
        Objects.requireNonNull(forecast, "forecast");
        missingInputs = List.copyOf(missingInputs);
    }

    /**
     * Starts an estimate for {@code today} to {@code horizonEnd} inclusive,
     * normally the day before the next selected payday.
     *
     * @param ledger     the ledger
     * @param today      the workspace's local date
     * @param horizonEnd last day of the horizon
     * @return a builder
     */
    public static Builder builder(LedgerProjection ledger, LocalDate today, LocalDate horizonEnd) {
        return new Builder(ledger, today, horizonEnd);
    }

    private Money smaller() {
        return budgetLimit != null && budgetLimit.compareTo(cashLimit) < 0 ? budgetLimit : cashLimit;
    }

    /** Returns the smaller limit (the cash limit alone without a budget), never below zero. */
    public Money estimate() {
        Money smaller = smaller();
        return smaller.isNegative() ? Money.zero(smaller.currency()) : smaller;
    }

    /** Returns how far the smaller limit is below zero, shown beside the estimate. */
    public Money shortfall() {
        Money smaller = smaller();
        return smaller.isNegative() ? smaller.negate() : Money.zero(smaller.currency());
    }

    /** Returns whether no input is missing or stale. */
    public boolean complete() {
        return missingInputs.isEmpty();
    }

    public LocalDate horizonStart() {
        return forecast.start();
    }

    public LocalDate horizonEnd() {
        return forecast.end();
    }

    public Money lowestBalance() {
        return forecast.lowestBalance();
    }

    public LocalDate lowestBalanceDate() {
        return forecast.lowestDate();
    }

    /**
     * Estimates discretionary spending available over the horizon (BUD 07).
     * <ul>
     * <li>Budget limit: Σ remaining after pending of discretionary categories
     * (allocations in groups flagged discretionary) in the budget period
     * containing today, less the outstanding amount of confirmed expense
     * occurrences in those categories due from today to the earlier of the
     * horizon end and the period end.</li>
     * <li>Cash limit: the lowest closing balance of a {@link CashForecast}
     * over the horizon, with no scenario, less the minimum buffer.</li>
     * <li>Missing inputs, in order: {@code budget}, {@code minimumBuffer},
     * then per eligible account in ascending id order
     * {@code accountData:<id>} (no freshness date) or
     * {@code staleAccountData:<id>} (older than {@code staleAfterDays}
     * before today).</li>
     * </ul>
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final LedgerProjection ledger;
        private final LocalDate today;
        private final LocalDate horizonEnd;
        private BudgetPlan plan;
        private List<BudgetAdjustment> adjustments = List.of();
        private List<RecurringSchedule> schedules = List.of();
        private List<OccurrenceOverride> overrides = List.of();
        private List<OccurrencePayment> payments = List.of();
        private List<Reservation> reservations = List.of();
        private Money minimumBuffer;
        private Map<String, LocalDate> accountDataAsOf = Map.of();
        private int staleAfterDays = 3;

        private Builder(LedgerProjection ledger, LocalDate today, LocalDate horizonEnd) {
            this.ledger = Objects.requireNonNull(ledger, "ledger");
            this.today = Objects.requireNonNull(today, "today");
            this.horizonEnd = Objects.requireNonNull(horizonEnd, "horizonEnd");
        }

        /** Sets the budget, or null when there is none. */
        public Builder plan(BudgetPlan value) {
            this.plan = value;
            return this;
        }

        public Builder adjustments(List<BudgetAdjustment> value) {
            this.adjustments = List.copyOf(value);
            return this;
        }

        public Builder schedules(List<RecurringSchedule> value) {
            this.schedules = List.copyOf(value);
            return this;
        }

        public Builder overrides(List<OccurrenceOverride> value) {
            this.overrides = List.copyOf(value);
            return this;
        }

        public Builder payments(List<OccurrencePayment> value) {
            this.payments = List.copyOf(value);
            return this;
        }

        public Builder reservations(List<Reservation> value) {
            this.reservations = List.copyOf(value);
            return this;
        }

        /** Sets the minimum buffer, or null when the user has not set one. */
        public Builder minimumBuffer(Money value) {
            this.minimumBuffer = value;
            return this;
        }

        /** Sets the date each account's data is known to be complete to. */
        public Builder accountDataAsOf(Map<String, LocalDate> value) {
            this.accountDataAsOf = Map.copyOf(value);
            return this;
        }

        /** Sets how many days old account data may be before it is stale. */
        public Builder staleAfterDays(int value) {
            this.staleAfterDays = value;
            return this;
        }

        /**
         * Builds the estimate.
         *
         * @return the estimate
         */
        public DiscretionaryEstimate build() {
            Money zero = Money.zero(ledger.chart().currency());
            List<String> missing = new ArrayList<>();
            CashForecast forecast = CashForecast.builder(ledger, today)
                    .end(horizonEnd)
                    .schedules(schedules)
                    .overrides(overrides)
                    .payments(payments)
                    .reservations(reservations)
                    .build();

            Money remaining = null;
            Money commitments = null;
            BudgetPeriodEvaluation evaluation = plan == null ? null
                    : new BudgetEvaluator(plan, ledger, adjustments).evaluateAt(today);
            BudgetVersion version = evaluation == null ? null : evaluation.version();
            Set<String> targets = new LinkedHashSet<>();
            if (evaluation != null && version != null) {
                for (BudgetLine line : evaluation.lines()) {
                    BudgetGroup group = line.groupId() == null ? null : version.group(line.groupId());
                    if (group != null && group.discretionary()) {
                        targets.add(line.categoryId());
                    }
                }
            }
            if (evaluation == null || version == null || targets.isEmpty()) {
                missing.add("budget");
            } else {
                remaining = zero;
                for (BudgetLine line : evaluation.lines()) {
                    if (targets.contains(line.categoryId())) {
                        remaining = remaining.plus(line.remainingAfterPending());
                    }
                }
                Map<String, JournalStatus> statuses = new HashMap<>();
                for (Journal journal : ledger.journals()) {
                    statuses.put(journal.id(), journal.status());
                }
                LocalDate periodEnd = evaluation.period().end();
                LocalDate until = horizonEnd.isBefore(periodEnd) ? horizonEnd : periodEnd;
                commitments = zero;
                for (RecurringSchedule schedule : schedules) {
                    if (schedule.kind() != ScheduleKind.EXPENSE || !schedule.confirmed()
                            || !targets.contains(schedule.categoryId())) {
                        continue;
                    }
                    for (ScheduledOccurrence occurrence : schedule.occurrencesBetween(today, until, overrides)) {
                        commitments = commitments.plus(
                                OccurrenceState.assess(occurrence, payments, statuses, today, null).outstanding());
                    }
                }
            }

            if (minimumBuffer == null) {
                missing.add("minimumBuffer");
            }
            Money buffer = minimumBuffer != null ? minimumBuffer : zero;
            LocalDate staleBefore = today.minusDays(staleAfterDays);
            LocalDate freshness = null;
            for (String id : forecast.accountIds().stream().sorted().toList()) {
                LocalDate asOf = accountDataAsOf.get(id);
                if (asOf == null) {
                    missing.add("accountData:" + id);
                    continue;
                }
                if (asOf.isBefore(staleBefore)) {
                    missing.add("staleAccountData:" + id);
                }
                if (freshness == null || asOf.isBefore(freshness)) {
                    freshness = asOf;
                }
            }

            return new DiscretionaryEstimate(remaining == null ? null : remaining.minus(commitments),
                    forecast.lowestBalance().minus(buffer), remaining, commitments, buffer, forecast, freshness,
                    missing);
        }
    }
}
