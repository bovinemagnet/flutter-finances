package com.paulsnow.finance.core.planning;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import com.paulsnow.finance.core.ledger.Account;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;

/**
 * A day-by-day projection of eligible cash from {@code start} to {@code end}
 * inclusive (PLAN 03). Build one with {@link #builder(LedgerProjection, LocalDate)}.
 *
 * @param start          first day, the workspace's today
 * @param end            last day
 * @param accountIds     eligible cash accounts included in the projection
 * @param openingBalance posted balance of eligible accounts at the end of {@code start}'s ledger day
 * @param days           one entry per day from {@code start} to {@code end}
 * @author Paul Snow
 * @since 0.0.0
 */
public record CashForecast(LocalDate start, LocalDate end, Set<String> accountIds, Money openingBalance,
        List<ForecastDay> days) {

    public CashForecast {
        Objects.requireNonNull(start, "start");
        Objects.requireNonNull(end, "end");
        Objects.requireNonNull(openingBalance, "openingBalance");
        accountIds = Collections.unmodifiableSet(new LinkedHashSet<>(accountIds));
        days = List.copyOf(days);
        if (days.isEmpty()) {
            throw new IllegalArgumentException("A forecast has at least one day");
        }
    }

    /**
     * Returns whether an account's money counts in cash forecasts: liquid
     * (transaction, savings or cash), not archived and included in
     * forecasts. Credit limits, loans, property, investments and
     * superannuation never count.
     *
     * @param account the account
     * @return true when eligible
     */
    public static boolean isEligible(Account account) {
        return account.includeInForecast() && account.type().isLiquid() && !account.archived();
    }

    /**
     * Returns the signed cash effect of one occurrence of {@code schedule} per
     * account: bills and transfers leave the paying account, income and
     * transfers arrive in the receiving account.
     *
     * @param schedule the schedule
     * @param amount   positive occurrence amount
     * @return the effects
     */
    public static List<CashEffect> cashEffects(RecurringSchedule schedule, Money amount) {
        return switch (schedule.kind()) {
            case EXPENSE -> List.of(new CashEffect(schedule.accountId(), amount.negate()));
            case INCOME -> List.of(new CashEffect(schedule.accountId(), amount));
            case TRANSFER -> List.of(new CashEffect(schedule.accountId(), amount.negate()),
                    new CashEffect(schedule.counterAccountId(), amount));
        };
    }

    /**
     * Starts a forecast of {@code ledger} from {@code today} over the default
     * 90-day horizon.
     *
     * @param ledger the ledger
     * @param today  the workspace's local date
     * @return a builder
     */
    public static Builder builder(LedgerProjection ledger, LocalDate today) {
        return new Builder(ledger, today);
    }

    /** Returns the earliest day with the lowest closing balance. */
    public ForecastDay lowestDay() {
        ForecastDay lowest = days.getFirst();
        for (ForecastDay day : days) {
            if (day.closing().compareTo(lowest.closing()) < 0) {
                lowest = day;
            }
        }
        return lowest;
    }

    /** Returns the lowest closing balance over the horizon. */
    public Money lowestBalance() {
        return lowestDay().closing();
    }

    /** Returns the earliest date on which {@link #lowestBalance()} occurs. */
    public LocalDate lowestDate() {
        return lowestDay().date();
    }

    /** Returns every line in date order. */
    public List<ForecastLine> lines() {
        List<ForecastLine> lines = new ArrayList<>();
        days.forEach(d -> lines.addAll(d.lines()));
        return lines;
    }

    /** Returns whether any line is hypothetical. */
    public boolean includesHypothetical() {
        return lines().stream().anyMatch(l -> l.certainty() == ForecastCertainty.HYPOTHETICAL);
    }

    /**
     * Returns the projected day for {@code date}.
     *
     * @param date the date
     * @return the day, or null outside the horizon
     */
    public ForecastDay day(LocalDate date) {
        long index = ChronoUnit.DAYS.between(start, date);
        return index < 0 || index >= days.size() ? null : days.get((int) index);
    }

    /**
     * A signed cash movement on one account.
     *
     * @param accountId the account
     * @param amount    positive adds cash, negative removes it
     * @author Paul Snow
     * @since 0.0.0
     */
    public record CashEffect(String accountId, Money amount) {
    }

    /**
     * Projects eligible cash day by day (PLAN 03).
     * <ul>
     * <li>Opening: posted and reversed journals dated on or before today, on
     * eligible accounts.</li>
     * <li>Actual lines: posted and reversed journals dated after today within
     * the horizon, and pending journals dated up to the horizon end (on their
     * date, or today if earlier). Drafts are ignored.</li>
     * <li>Committed lines: confirmed reservations in eligible accounts (today),
     * and the outstanding amount of each non-skipped occurrence of each
     * confirmed schedule due from {@code today − overdueLookbackDays} to the
     * end (overdue ones today). Occurrences linked to posted or pending
     * journals are consumed, so a paid bill is never counted twice (A13).
     * Transfers affect each eligible side; unconfirmed schedules are left
     * out.</li>
     * <li>Hypothetical lines: whatever the scenario adds or changes.</li>
     * </ul>
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final LedgerProjection ledger;
        private final LocalDate today;
        private int horizonDays = 90;
        private LocalDate end;
        private List<RecurringSchedule> schedules = List.of();
        private List<OccurrenceOverride> overrides = List.of();
        private List<OccurrencePayment> payments = List.of();
        private List<Reservation> reservations = List.of();
        private Scenario scenario;
        private int overdueLookbackDays;

        private Builder(LedgerProjection ledger, LocalDate today) {
            this.ledger = Objects.requireNonNull(ledger, "ledger");
            this.today = Objects.requireNonNull(today, "today");
        }

        /** Sets the number of days from today; ignored when {@link #end(LocalDate)} is set. */
        public Builder horizonDays(int value) {
            this.horizonDays = value;
            return this;
        }

        /** Sets the last day of the horizon, inclusive. */
        public Builder end(LocalDate value) {
            this.end = value;
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

        /** Sets the what-if to apply, or null for none. */
        public Builder scenario(Scenario value) {
            this.scenario = value;
            return this;
        }

        /** Sets how many days before today overdue occurrences are still projected (on today). */
        public Builder overdueLookbackDays(int value) {
            this.overdueLookbackDays = value;
            return this;
        }

        /**
         * Builds the forecast.
         *
         * @return the forecast
         * @throws IllegalArgumentException when the horizon ends before today
         */
        public CashForecast build() {
            Chart chart = ledger.chart();
            CurrencyUnit currency = chart.currency();
            LocalDate last = end != null ? end : today.plusDays(horizonDays - 1L);
            if (last.isBefore(today)) {
                throw new IllegalArgumentException("The horizon ends before today");
            }
            Set<String> eligible = new LinkedHashSet<>();
            for (Account account : chart.accounts()) {
                if (isEligible(account)) {
                    eligible.add(account.id());
                }
            }
            List<ForecastLine> lines = new ArrayList<>();

            long opening = 0;
            Map<String, JournalStatus> statuses = new HashMap<>();
            for (Journal journal : ledger.journals()) {
                statuses.put(journal.id(), journal.status());
                boolean posted = journal.status().inPostedLedger();
                if (!posted && journal.status() != JournalStatus.PENDING) {
                    continue;
                }
                LocalDate date = journal.effectiveDate();
                if (posted && !date.isAfter(today)) {
                    for (Posting p : journal.postings()) {
                        if (eligible.contains(p.ledgerAccountId())) {
                            opening = Math.addExact(opening, p.amountMinor());
                        }
                    }
                    continue;
                }
                if (date.isAfter(last)) {
                    continue;
                }
                Map<String, Long> byAccount = new LinkedHashMap<>();
                for (Posting p : journal.postings()) {
                    if (eligible.contains(p.ledgerAccountId())) {
                        byAccount.merge(p.ledgerAccountId(), p.amountMinor(), Math::addExact);
                    }
                }
                byAccount.forEach((account, minor) -> lines.add(new ForecastLine(notBeforeToday(date), account,
                        new Money(minor, currency), ForecastCertainty.ACTUAL,
                        posted ? ForecastSource.POSTED : ForecastSource.PENDING, journal.id(), journal.payee())));
            }

            for (Reservation r : reservations) {
                if (!r.confirmed() || !eligible.contains(r.accountId())) {
                    continue;
                }
                lines.add(new ForecastLine(today, r.accountId(), r.amount().negate(), ForecastCertainty.COMMITTED,
                        ForecastSource.RESERVATION, r.id(), null));
            }

            List<ScenarioChange> changes = scenario == null ? List.of() : scenario.changes();
            Set<String> removed = new HashSet<>();
            Map<String, Money> amounts = new HashMap<>();
            List<RecurringSchedule> added = new ArrayList<>();
            for (ScenarioChange change : changes) {
                switch (change) {
                    case ScenarioChange.RemoveSchedule c -> removed.add(c.scheduleId());
                    case ScenarioChange.ScheduleAmount c -> amounts.put(c.scheduleId(), c.amount());
                    case ScenarioChange.AddSchedule c -> added.add(c.schedule());
                    case ScenarioChange.OneOff c -> {
                        // Applied after schedules, below.
                    }
                }
            }
            List<Projected> projected = new ArrayList<>();
            for (RecurringSchedule schedule : schedules) {
                if (!removed.contains(schedule.id())) {
                    projected.add(new Projected(schedule, amounts.containsKey(schedule.id())));
                }
            }
            added.forEach(s -> projected.add(new Projected(s, true)));

            for (Projected entry : projected) {
                RecurringSchedule schedule = entry.schedule();
                if (!schedule.confirmed()) {
                    continue;
                }
                RecurringSchedule effective = amounts.containsKey(schedule.id())
                        ? schedule.withAmount(amounts.get(schedule.id()))
                        : schedule;
                for (ScheduledOccurrence occurrence : effective.occurrencesBetween(
                        today.minusDays(overdueLookbackDays), last, overrides)) {
                    if (occurrence.skipped()) {
                        continue;
                    }
                    Money outstanding = OccurrenceState.assess(occurrence, payments, statuses, today, null)
                            .outstanding();
                    if (outstanding.isZero()) {
                        continue;
                    }
                    for (CashEffect effect : cashEffects(effective, outstanding)) {
                        if (!eligible.contains(effect.accountId())) {
                            continue;
                        }
                        lines.add(new ForecastLine(notBeforeToday(occurrence.dueDate()), effect.accountId(),
                                effect.amount(),
                                entry.hypothetical() ? ForecastCertainty.HYPOTHETICAL : ForecastCertainty.COMMITTED,
                                ForecastSource.SCHEDULE, occurrence.key(), schedule.name()));
                    }
                }
            }

            for (ScenarioChange change : changes) {
                if (change instanceof ScenarioChange.OneOff c && eligible.contains(c.accountId())
                        && !c.date().isBefore(today) && !c.date().isAfter(last)) {
                    lines.add(new ForecastLine(c.date(), c.accountId(), c.amount(), ForecastCertainty.HYPOTHETICAL,
                            ForecastSource.SCENARIO, c.id(), c.description()));
                }
            }

            Map<LocalDate, List<ForecastLine>> byDay = new HashMap<>();
            for (ForecastLine line : lines) {
                byDay.computeIfAbsent(line.date(), d -> new ArrayList<>()).add(line);
            }
            List<ForecastDay> days = new ArrayList<>();
            Money balance = new Money(opening, currency);
            for (LocalDate date = today; !date.isAfter(last); date = date.plusDays(1)) {
                ForecastDay day = ForecastDay.of(date, balance, byDay.getOrDefault(date, List.of()));
                days.add(day);
                balance = day.closing();
            }
            return new CashForecast(today, last, eligible, new Money(opening, currency), days);
        }

        private LocalDate notBeforeToday(LocalDate date) {
            return date.isBefore(today) ? today : date;
        }

        private record Projected(RecurringSchedule schedule, boolean hypothetical) {
        }
    }
}
