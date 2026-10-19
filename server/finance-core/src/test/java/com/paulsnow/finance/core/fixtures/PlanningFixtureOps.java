package com.paulsnow.finance.core.fixtures;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.paulsnow.finance.core.ledger.Account;
import com.paulsnow.finance.core.ledger.AccountType;
import com.paulsnow.finance.core.ledger.Category;
import com.paulsnow.finance.core.ledger.CategoryKind;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalFactory;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Split;
import com.paulsnow.finance.core.ledger.TransactionDraft;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.planning.BudgetAllocation;
import com.paulsnow.finance.core.planning.BudgetGroup;
import com.paulsnow.finance.core.planning.BudgetPeriod;
import com.paulsnow.finance.core.planning.BudgetPlan;
import com.paulsnow.finance.core.planning.BudgetRemaining;
import com.paulsnow.finance.core.planning.BudgetVersion;
import com.paulsnow.finance.core.planning.CashForecast;
import com.paulsnow.finance.core.planning.DiscretionaryEstimate;
import com.paulsnow.finance.core.planning.ForecastCertainty;
import com.paulsnow.finance.core.planning.ForecastLine;
import com.paulsnow.finance.core.planning.Frequency;
import com.paulsnow.finance.core.planning.MonthEndRule;
import com.paulsnow.finance.core.planning.MonthlyEstimate;
import com.paulsnow.finance.core.planning.OccurrenceOverride;
import com.paulsnow.finance.core.planning.OccurrencePayment;
import com.paulsnow.finance.core.planning.PeriodCycle;
import com.paulsnow.finance.core.planning.PeriodSchedule;
import com.paulsnow.finance.core.planning.Recurrence;
import com.paulsnow.finance.core.planning.RecurringSchedule;
import com.paulsnow.finance.core.planning.Reservation;
import com.paulsnow.finance.core.planning.RolloverPolicy;
import com.paulsnow.finance.core.planning.Scenario;
import com.paulsnow.finance.core.planning.ScenarioChange;
import com.paulsnow.finance.core.planning.ScheduleKind;
import com.paulsnow.finance.core.planning.TemplateAllocation;
import com.paulsnow.finance.core.planning.TemplateGroup;

import tools.jackson.databind.JsonNode;

/**
 * Java handlers for budgeting, schedule and forecast fixture operations.
 * Each mirrors the Dart handler of the same name in
 * {@code packages/finance_core/test/fixtures/planning_ops.dart}; semantics
 * are documented in {@code spec/fixtures/README.md} under "Planning
 * operations".
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class PlanningFixtureOps {

    private PlanningFixtureOps() {
    }

    static Map<String, FixtureOp> all() {
        Map<String, FixtureOp> ops = new LinkedHashMap<>();
        ops.put("periods.generate", PlanningFixtureOps::periodsGenerate);
        ops.put("schedule.occurrences", PlanningFixtureOps::scheduleOccurrences);
        ops.put("budget.remaining", PlanningFixtureOps::budgetRemaining);
        ops.put("rollover.next", PlanningFixtureOps::rolloverNext);
        ops.put("allocation.template", PlanningFixtureOps::allocationTemplate);
        ops.put("monthly.equivalent", PlanningFixtureOps::monthlyEquivalent);
        ops.put("discretionary.estimate", PlanningFixtureOps::discretionaryEstimate);
        ops.put("forecast.daily", PlanningFixtureOps::forecastDaily);
        return Map.copyOf(ops);
    }

    private static LocalDate date(JsonNode text) {
        return LocalDate.parse(text.asString());
    }

    private static LocalDate optionalDate(JsonNode text) {
        return text.isMissingNode() || text.isNull() ? null : date(text);
    }

    private static Integer optionalInt(JsonNode value) {
        return value.isMissingNode() || value.isNull() ? null : value.asInt();
    }

    private static CurrencyUnit currency(JsonNode input) {
        return new CurrencyUnit(input.path("currency").asString("AUD"), input.path("exponent").asInt(2));
    }

    private static MonthEndRule monthEnd(JsonNode name) {
        return MonthEndRule.fromWire(name.asString("clamp"));
    }

    private static List<String> strings(JsonNode array) {
        List<String> values = new ArrayList<>();
        array.forEach(v -> values.add(v.asString()));
        return values;
    }

    private static void periodsGenerate(JsonNode input, JsonNode expected) {
        PeriodSchedule schedule = new PeriodSchedule(PeriodCycle.fromWire(input.path("cycle").asString()),
                date(input.path("anchor")), optionalInt(input.path("lengthDays")), RolloverPolicy.NONE,
                monthEnd(input.path("endOfMonth")));
        List<Map<String, String>> actual = new ArrayList<>();
        for (BudgetPeriod period : schedule.generate(input.path("count").asInt())) {
            actual.add(Map.of("start", period.start().toString(), "end", period.end().toString()));
        }
        List<Map<String, String>> want = new ArrayList<>();
        for (JsonNode period : expected.path("periods")) {
            want.add(Map.of("start", period.path("start").asString(), "end", period.path("end").asString()));
        }
        assertThat(actual).isEqualTo(want);
    }

    private static Recurrence recurrence(JsonNode input) {
        return Recurrence.builder(Frequency.fromWire(input.path("frequency").asString()), date(input.path("start")))
                .interval(input.path("interval").asInt(1))
                .until(optionalDate(input.path("until")))
                .count(optionalInt(input.path("count")))
                .monthEnd(monthEnd(input.path("endOfMonth")))
                .dayOfMonth(optionalInt(input.path("dayOfMonth")))
                .build();
    }

    private static void scheduleOccurrences(JsonNode input, JsonNode expected) {
        Object result;
        try {
            result = recurrence(input).dates().stream().map(LocalDate::toString).toList();
        } catch (IllegalStateException e) {
            result = "UNBOUNDED";
        } catch (IllegalArgumentException e) {
            result = "INVALID";
        }
        Object want = expected.has("dates") ? strings(expected.path("dates")) : expected.path("error").asString();
        assertThat(result).isEqualTo(want);
    }

    private static void budgetRemaining(JsonNode input, JsonNode expected) {
        CurrencyUnit currency = currency(input);
        BudgetRemaining result = BudgetRemaining.of(money(input.path("planned"), currency),
                money(input.path("rollover"), currency), money(input.path("adjustments"), currency),
                money(input.path("postedNet"), currency), money(input.path("pending"), currency));
        assertThat(result.remaining().toDecimalString()).as("remaining")
                .isEqualTo(expected.path("remaining").asString());
        assertThat(result.remainingAfterPending().toDecimalString()).as("remainingAfterPending")
                .isEqualTo(expected.path("remainingAfterPending").asString());
    }

    private static void rolloverNext(JsonNode input, JsonNode expected) {
        RolloverPolicy policy = RolloverPolicy.fromWire(input.path("policy").asString());
        Money remaining = money(input.path("remaining"), currency(input));
        assertThat(policy.nextOpening(remaining).toDecimalString()).isEqualTo(expected.path("opening").asString());
    }

    private static void allocationTemplate(JsonNode input, JsonNode expected) {
        CurrencyUnit currency = currency(input);
        List<String> groups = strings(input.path("groups"));
        List<TemplateGroup> template = new ArrayList<>();
        for (int i = 0; i < groups.size(); i++) {
            template.add(new TemplateGroup(groups.get(i), input.path("weights").get(i).asInt()));
        }
        TemplateAllocation result = TemplateAllocation.allocate(money(input.path("income"), currency), template);
        Map<String, String> amounts = new LinkedHashMap<>();
        result.amounts().forEach((group, amount) -> amounts.put(group, amount.toDecimalString()));
        Map<String, String> want = new LinkedHashMap<>();
        expected.path("amounts").properties().forEach(e -> want.put(e.getKey(), e.getValue().asString()));
        assertThat(amounts).as("amounts").isEqualTo(want);
        assertThat(result.unassigned().toDecimalString()).as("unassigned")
                .isEqualTo(expected.path("unassigned").asString());
    }

    private static void monthlyEquivalent(JsonNode input, JsonNode expected) {
        MonthlyEstimate result = MonthlyEstimate.of(money(input.path("amount"), currency(input)),
                Frequency.fromWire(input.path("frequency").asString()), input.path("interval").asInt(1));
        assertThat(result.amount().toDecimalString()).as("amount").isEqualTo(expected.path("amount").asString());
        assertThat(result.annualFactor()).as("annualFactor").isEqualTo(expected.path("annualFactor").asString());
        assertThat(result.isEstimate()).as("isEstimate").isEqualTo(expected.path("isEstimate").asBoolean());
    }

    private static void discretionaryEstimate(JsonNode input, JsonNode expected) {
        PlanningScenario scenario = new PlanningScenario(input);
        JsonNode budget = input.path("budget");
        BudgetPlan plan = null;
        if (!budget.isMissingNode() && !budget.isNull()) {
            List<BudgetGroup> groups = new ArrayList<>();
            for (JsonNode g : budget.path("groups")) {
                groups.add(new BudgetGroup(g.path("id").asString(), g.path("id").asString(),
                        g.path("share").asInt(), g.path("discretionary").asBoolean(false)));
            }
            List<BudgetAllocation> allocations = new ArrayList<>();
            for (JsonNode a : budget.path("allocations")) {
                allocations.add(BudgetAllocation.category(a.path("category").asString(),
                        scenario.money(a.path("planned")), a.hasNonNull("group") ? a.path("group").asString() : null));
            }
            LocalDate anchor = date(budget.path("anchor"));
            plan = new BudgetPlan("plan", "plan",
                    new PeriodSchedule(PeriodCycle.fromWire(budget.path("cycle").asString()), anchor,
                            optionalInt(budget.path("lengthDays"))),
                    List.of(new BudgetVersion("version", anchor, scenario.money(budget.path("income")), groups,
                            allocations)));
        }
        DiscretionaryEstimate result = DiscretionaryEstimate.builder(scenario.ledger, scenario.today,
                        date(input.path("horizonEnd")))
                .plan(plan)
                .schedules(scenario.schedules)
                .overrides(scenario.overrides)
                .payments(scenario.payments)
                .reservations(scenario.reservations)
                .minimumBuffer(input.hasNonNull("buffer") ? scenario.money(input.path("buffer")) : null)
                .accountDataAsOf(scenario.dataAsOf)
                .staleAfterDays(input.path("staleAfterDays").asInt(3))
                .build();
        assertThat(text(result.budgetLimit())).as("budgetLimit").isEqualTo(optionalText(expected.path("budgetLimit")));
        assertThat(text(result.cashLimit())).as("cashLimit").isEqualTo(optionalText(expected.path("cashLimit")));
        assertThat(text(result.estimate())).as("estimate").isEqualTo(optionalText(expected.path("estimate")));
        assertThat(text(result.shortfall())).as("shortfall").isEqualTo(optionalText(expected.path("shortfall")));
        assertThat(result.complete()).as("complete").isEqualTo(expected.path("complete").asBoolean());
        if (expected.has("missingInputs")) {
            assertThat(result.missingInputs()).as("missingInputs").isEqualTo(strings(expected.path("missingInputs")));
        }
        if (expected.has("lowestDate")) {
            assertThat(result.lowestBalanceDate().toString()).as("lowestDate")
                    .isEqualTo(expected.path("lowestDate").asString());
        }
    }

    private static void forecastDaily(JsonNode input, JsonNode expected) {
        PlanningScenario scenario = new PlanningScenario(input);
        List<ScenarioChange> changes = new ArrayList<>();
        for (JsonNode c : input.path("scenario")) {
            String id = c.path("id").asString();
            changes.add(switch (c.path("type").asString()) {
                case "oneOff" -> new ScenarioChange.OneOff(id, date(c.path("date")), c.path("account").asString(),
                        scenario.money(c.path("amount")), null);
                case "scheduleAmount" -> new ScenarioChange.ScheduleAmount(id, c.path("schedule").asString(),
                        scenario.money(c.path("amount")));
                case "removeSchedule" -> new ScenarioChange.RemoveSchedule(id, c.path("schedule").asString());
                default -> throw new IllegalArgumentException("Unknown scenario change " + c.path("type"));
            });
        }
        int horizonDays = input.path("horizonDays").asInt(90);
        CashForecast forecast = CashForecast.builder(scenario.ledger, scenario.today)
                .horizonDays(horizonDays)
                .schedules(scenario.schedules)
                .overrides(scenario.overrides)
                .payments(scenario.payments)
                .reservations(scenario.reservations)
                .scenario(changes.isEmpty() ? null : new Scenario("scenario", "scenario", changes))
                .build();
        assertThat(forecast.days()).as("days").hasSize(horizonDays);
        assertThat(text(forecast.openingBalance())).as("openingBalance")
                .isEqualTo(expected.path("openingBalance").asString());
        assertThat(text(forecast.lowestBalance())).as("lowestBalance")
                .isEqualTo(expected.path("lowestBalance").asString());
        assertThat(forecast.lowestDate().toString()).as("lowestDate")
                .isEqualTo(expected.path("lowestDate").asString());
        expected.path("days").properties().forEach(e -> assertThat(
                text(forecast.day(LocalDate.parse(e.getKey())).closing()))
                .as("closing " + e.getKey()).isEqualTo(e.getValue().asString()));
        Map<ForecastCertainty, Money> totals = new EnumMap<>(ForecastCertainty.class);
        for (ForecastCertainty certainty : ForecastCertainty.values()) {
            totals.put(certainty, Money.zero(scenario.currency));
        }
        for (ForecastLine line : forecast.lines()) {
            totals.merge(line.certainty(), line.amount(), Money::plus);
        }
        expected.path("certaintyTotals").properties().forEach(e -> {
            ForecastCertainty certainty = ForecastCertainty.valueOf(e.getKey().toUpperCase(java.util.Locale.ROOT));
            assertThat(text(totals.get(certainty))).as(e.getKey()).isEqualTo(e.getValue().asString());
        });
    }

    private static Money money(JsonNode text, CurrencyUnit currency) {
        return Money.parse(text.asString(), currency);
    }

    private static String text(Money value) {
        return value == null ? null : value.toDecimalString();
    }

    private static String optionalText(JsonNode value) {
        return value.isMissingNode() || value.isNull() ? null : value.asString();
    }

    /**
     * Accounts, categories, entries, schedules, payments and reservations
     * shared by the forecast and discretionary operations.
     */
    private static final class PlanningScenario {
        final CurrencyUnit currency;
        final LocalDate today;
        final LedgerProjection ledger;
        final List<RecurringSchedule> schedules = new ArrayList<>();
        final List<OccurrenceOverride> overrides = new ArrayList<>();
        final List<OccurrencePayment> payments = new ArrayList<>();
        final List<Reservation> reservations = new ArrayList<>();
        final Map<String, LocalDate> dataAsOf = new LinkedHashMap<>();

        PlanningScenario(JsonNode input) {
            currency = currency(input);
            today = date(input.path("today"));
            List<Account> accounts = new ArrayList<>();
            for (JsonNode a : input.path("accounts")) {
                accounts.add(Account.builder(a.path("id").asString(), a.path("id").asString(),
                                AccountType.fromWire(a.path("type").asString()))
                        .includeInForecast(a.path("includeInForecast").asBoolean(true))
                        .build());
                if (a.hasNonNull("dataAsOf")) {
                    dataAsOf.put(a.path("id").asString(), date(a.path("dataAsOf")));
                }
            }
            List<Category> categories = new ArrayList<>();
            for (JsonNode c : input.path("categories")) {
                categories.add(new Category(c.path("id").asString(), c.path("id").asString(),
                        CategoryKind.fromWire(c.path("kind").asString("expense")), null, false));
            }
            Chart chart = new Chart(currency, accounts, categories);
            JournalFactory factory = new JournalFactory(chart);
            List<Journal> journals = new ArrayList<>();
            for (JsonNode a : input.path("accounts")) {
                if (a.hasNonNull("balance")) {
                    journals.add(factory.build(TransactionDraft.builder(TransactionType.OPENING_BALANCE,
                                    a.path("id").asString(), money(a.path("balance")), today)
                            .id("opening:" + a.path("id").asString())
                            .build()));
                }
            }
            for (JsonNode e : input.path("entries")) {
                Money amount = money(e.path("amount"));
                journals.add(factory.build(TransactionDraft.builder(TransactionType.fromWire(e.path("type").asString()),
                                e.path("account").asString(), amount, date(e.path("date")))
                        .id(e.path("id").asString())
                        .counterAccountId(e.hasNonNull("to") ? e.path("to").asString() : null)
                        .status(JournalStatus.fromWire(e.path("status").asString("posted")))
                        .splits(e.hasNonNull("category")
                                ? List.of(new Split(e.path("category").asString(), amount))
                                : List.of())
                        .build()));
            }
            ledger = new LedgerProjection(chart, journals);
            for (JsonNode s : input.path("schedules")) {
                schedules.add(RecurringSchedule.builder(s.path("id").asString(),
                                ScheduleKind.fromWire(s.path("kind").asString()), recurrence(s),
                                money(s.path("amount")), s.path("account").asString())
                        .isEstimate(s.path("estimate").asBoolean(false))
                        .counterAccountId(s.hasNonNull("to") ? s.path("to").asString() : null)
                        .categoryId(s.hasNonNull("category") ? s.path("category").asString() : null)
                        .confirmed(s.path("confirmed").asBoolean(true))
                        .build());
            }
            for (JsonNode o : input.path("overrides")) {
                overrides.add(new OccurrenceOverride(
                        o.path("schedule").asString() + "@" + o.path("originalDate").asString(),
                        o.path("schedule").asString(), date(o.path("originalDate")), optionalDate(o.path("dueDate")),
                        o.hasNonNull("amount") ? money(o.path("amount")) : null,
                        o.path("skipped").asBoolean(false)));
            }
            for (JsonNode p : input.path("payments")) {
                payments.add(new OccurrencePayment(p.path("journal").asString(), p.path("schedule").asString(),
                        date(p.path("occurrence")), p.path("journal").asString(), money(p.path("amount")),
                        p.path("settles").asBoolean(false)));
            }
            for (JsonNode r : input.path("reservations")) {
                String id = r.path("id").asString();
                reservations.add(new Reservation(id, r.hasNonNull("goal") ? r.path("goal").asString() : id,
                        r.path("account").asString(), money(r.path("amount")), r.path("confirmed").asBoolean(true)));
            }
        }

        Money money(JsonNode text) {
            return Money.parse(text.asString(), currency);
        }
    }
}
