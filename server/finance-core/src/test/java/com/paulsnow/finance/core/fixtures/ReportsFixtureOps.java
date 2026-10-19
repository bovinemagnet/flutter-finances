package com.paulsnow.finance.core.fixtures;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.paulsnow.finance.core.ledger.Account;
import com.paulsnow.finance.core.ledger.AccountType;
import com.paulsnow.finance.core.ledger.Category;
import com.paulsnow.finance.core.ledger.CategoryKind;
import com.paulsnow.finance.core.ledger.Chart;
import com.paulsnow.finance.core.ledger.CorrectionResult;
import com.paulsnow.finance.core.ledger.Corrections;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalFactory;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Split;
import com.paulsnow.finance.core.ledger.TransactionDraft;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.reports.DateRange;
import com.paulsnow.finance.core.reports.LedgerReports;
import com.paulsnow.finance.core.reports.Report;

import tools.jackson.databind.JsonNode;

/**
 * Java handler for {@code report.compute} ({@code spec/fixtures/reports.json}),
 * mirroring {@code reports_ops.dart}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class ReportsFixtureOps {

    private ReportsFixtureOps() {
    }

    static Map<String, FixtureOp> all() {
        return Map.of("report.compute", ReportsFixtureOps::reportCompute);
    }

    private static void reportCompute(JsonNode input, JsonNode expected) {
        CurrencyUnit currency = new CurrencyUnit(input.path("currency").asString(), input.path("exponent").asInt());
        List<Account> accounts = new ArrayList<>();
        for (JsonNode raw : input.path("accounts")) {
            accounts.add(Account.builder(raw.path("id").asString(), raw.path("id").asString(),
                    AccountType.fromWire(raw.path("type").asString()))
                    .includeInNetWorth(raw.path("includeInNetWorth").asBoolean(true)).build());
        }
        List<Category> categories = new ArrayList<>();
        for (JsonNode raw : input.path("categories")) {
            categories.add(new Category(raw.path("id").asString(), raw.path("id").asString(),
                    CategoryKind.fromWire(raw.path("kind").asString()), null, false));
        }
        Chart chart = new Chart(currency, accounts, categories);
        JournalFactory factory = new JournalFactory(chart);
        Map<String, Journal> journals = new LinkedHashMap<>();
        Map<String, String> refs = new LinkedHashMap<>();
        Map<String, String> refOfId = new LinkedHashMap<>();
        for (JsonNode entry : input.path("entries")) {
            if ("correct".equals(entry.path("type").asString())) {
                Journal target = journals.get(refs.get(entry.path("target").asString()));
                Journal replacement = factory.build(draft(entry.path("replacement"), currency, refs));
                CorrectionResult result = Corrections.correct(target, replacement);
                for (Journal journal : result.journals()) {
                    journals.put(journal.id(), journal);
                }
                refOfId.put(result.reversal().id(), entry.path("reversalRef").asString());
                refOfId.put(result.replacement().id(), entry.path("ref").asString());
                continue;
            }
            Journal journal = factory.build(draft(entry, currency, refs));
            journals.put(journal.id(), journal);
            refs.put(entry.path("ref").asString(), journal.id());
            refOfId.put(journal.id(), entry.path("ref").asString());
        }
        LedgerProjection ledger = new LedgerProjection(chart, journals.values());
        Report report = compute(ledger, input.path("report"));

        List<Map<String, Object>> actual = new ArrayList<>();
        for (Report.Row row : report.rows()) {
            Map<String, Object> view = new LinkedHashMap<>();
            view.put("key", row.key());
            view.put("label", row.label());
            Map<String, String> amounts = new LinkedHashMap<>();
            row.amounts().forEach((column, money) -> amounts.put(column, money.toDecimalString()));
            view.put("amounts", amounts);
            view.put("journals", row.journalIds().stream().map(refOfId::get).toList());
            actual.add(view);
        }
        List<Map<String, Object>> want = new ArrayList<>();
        JsonNode rows = expected.path("rows");
        for (int i = 0; i < rows.size(); i++) {
            JsonNode raw = rows.get(i);
            Map<String, Object> view = new LinkedHashMap<>();
            view.put("key", raw.path("key").asString());
            view.put("label", raw.has("label") ? raw.path("label").asString()
                    : i < actual.size() ? actual.get(i).get("label") : null);
            Map<String, String> amounts = new LinkedHashMap<>();
            raw.path("amounts").properties().forEach(e -> amounts.put(e.getKey(), e.getValue().asString()));
            view.put("amounts", amounts);
            List<String> journalRefs = new ArrayList<>();
            raw.path("journals").forEach(j -> journalRefs.add(j.asString()));
            view.put("journals", journalRefs);
            want.add(view);
        }
        assertThat(actual).isEqualTo(want);
    }

    static Report compute(LedgerProjection ledger, JsonNode spec) {
        String kind = spec.path("kind").asString();
        if ("account-balances".equals(kind)) {
            LocalDate asOf = spec.hasNonNull("asOf") ? LocalDate.parse(spec.path("asOf").asString()) : null;
            return LedgerReports.accountBalances(ledger, asOf);
        }
        DateRange range = range(spec.path("period"));
        return switch (kind) {
            case "income-vs-expenses" -> LedgerReports.incomeVsExpenses(ledger, range);
            case "spending-by-category" -> LedgerReports.spendingByCategory(ledger, range);
            case "spending-by-payee" -> LedgerReports.spendingByPayee(ledger, range);
            case "net-worth-history" -> LedgerReports.netWorthHistory(ledger, range);
            case "cash-flow" -> {
                Set<String> ids = new LinkedHashSet<>();
                spec.path("accounts").forEach(a -> ids.add(a.asString()));
                yield LedgerReports.cashFlow(ledger, range, ids);
            }
            default -> throw new AssertionError("Unknown report kind " + kind);
        };
    }

    private static DateRange range(JsonNode period) {
        return switch (period.path("type").asString()) {
            case "calendarYear" -> DateRange.calendarYear(period.path("year").asInt());
            case "financialYear" -> DateRange.financialYear(period.path("startYear").asInt());
            case "custom" -> new DateRange(LocalDate.parse(period.path("start").asString()),
                    LocalDate.parse(period.path("end").asString()));
            default -> throw new AssertionError("Unknown period " + period);
        };
    }

    private static TransactionDraft draft(JsonNode entry, CurrencyUnit currency, Map<String, String> refs) {
        List<Split> splits = new ArrayList<>();
        for (JsonNode split : entry.path("splits")) {
            splits.add(new Split(split.path("category").asString(), Money.parse(split.path("amount").asString(),
                    currency)));
        }
        return TransactionDraft.builder(TransactionType.fromWire(entry.path("type").asString()),
                        entry.path("account").asString(), Money.parse(entry.path("amount").asString(), currency),
                        LocalDate.parse(entry.path("date").asString()))
                .counterAccountId(entry.hasNonNull("to") ? entry.path("to").asString() : null)
                .status(JournalStatus.fromWire(entry.path("status").asString("posted")))
                .refundOf(entry.hasNonNull("refundOf") ? refs.get(entry.path("refundOf").asString()) : null)
                .payee(entry.hasNonNull("payee") ? entry.path("payee").asString() : null)
                .splits(splits)
                .build();
    }
}
