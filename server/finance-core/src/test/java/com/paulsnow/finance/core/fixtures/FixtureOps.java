package com.paulsnow.finance.core.fixtures;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
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
import com.paulsnow.finance.core.ledger.DraftException;
import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalFactory;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.JournalValidator;
import com.paulsnow.finance.core.ledger.LedgerError;
import com.paulsnow.finance.core.ledger.LedgerProjection;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.ledger.Split;
import com.paulsnow.finance.core.ledger.TransactionDraft;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.core.money.Allocation;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.money.MoneyFormatException;
import com.paulsnow.finance.core.money.MoneyRangeException;

import tools.jackson.databind.JsonNode;

/**
 * Java handlers for the shared fixture operations. Each mirrors the Dart
 * handler of the same name in {@code packages/finance_core/test/fixtures}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class FixtureOps {

    private FixtureOps() {
    }

    static Map<String, FixtureOp> all() {
        Map<String, FixtureOp> ops = new LinkedHashMap<>();
        ops.put("money.parse", FixtureOps::moneyParse);
        ops.put("money.allocate", FixtureOps::moneyAllocate);
        ops.put("journal.validate", FixtureOps::journalValidate);
        ops.put("ledger.scenario", FixtureOps::ledgerScenario);
        return Map.copyOf(ops);
    }

    private static void moneyParse(JsonNode input, JsonNode expected) {
        String separator = input.path("decimalSeparator").asString(".");
        Object result;
        try {
            result = Money.parseMinor(input.path("text").asString(), input.path("exponent").asInt(),
                    separator.charAt(0));
        } catch (MoneyFormatException e) {
            result = "FORMAT";
        } catch (MoneyRangeException e) {
            result = "OUT_OF_RANGE";
        }
        Object want = expected.has("minor") ? (Object) expected.path("minor").asLong()
                : expected.path("error").asString();
        assertThat(result).isEqualTo(want);
    }

    private static void moneyAllocate(JsonNode input, JsonNode expected) {
        List<Long> weights = new ArrayList<>();
        input.path("weights").forEach(w -> weights.add(w.asLong()));
        List<Long> parts = new ArrayList<>();
        expected.path("parts").forEach(p -> parts.add(p.asLong()));
        assertThat(Allocation.byWeights(input.path("total").asLong(), weights)).isEqualTo(parts);
    }

    private static void journalValidate(JsonNode input, JsonNode expected) {
        List<Posting> postings = new ArrayList<>();
        for (JsonNode raw : input.path("postings")) {
            postings.add(new Posting(raw.path("account").asString(), raw.path("minor").asLong(),
                    raw.path("currency").asString()));
        }
        Set<String> codes = new HashSet<>();
        for (LedgerError error : JournalValidator.validate(postings)) {
            codes.add(error.code());
        }
        Set<String> want = new HashSet<>();
        expected.path("errors").forEach(e -> want.add(e.asString()));
        assertThat(codes).isEqualTo(want);
    }

    private static void ledgerScenario(JsonNode input, JsonNode expected) {
        CurrencyUnit currency = new CurrencyUnit(input.path("currency").asString(), input.path("exponent").asInt());
        List<Account> accounts = new ArrayList<>();
        for (JsonNode raw : input.path("accounts")) {
            accounts.add(Account.builder(raw.path("id").asString(), raw.path("id").asString(),
                    AccountType.fromWire(raw.path("type").asString()))
                    .includeInNetWorth(raw.path("includeInNetWorth").asBoolean(true))
                    .build());
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
        List<Map<String, Object>> errors = new ArrayList<>();

        JsonNode entries = input.path("entries");
        for (int index = 0; index < entries.size(); index++) {
            JsonNode entry = entries.get(index);
            try {
                if ("correct".equals(entry.path("type").asString())) {
                    Journal target = journals.get(refs.get(entry.path("target").asString()));
                    Journal replacement = factory.build(draft(entry.path("replacement"), currency, refs));
                    CorrectionResult result = Corrections.correct(target, replacement);
                    for (Journal journal : result.journals()) {
                        journals.put(journal.id(), journal);
                    }
                    continue;
                }
                Journal journal = factory.build(draft(entry, currency, refs));
                journals.put(journal.id(), journal);
                if (entry.hasNonNull("ref")) {
                    refs.put(entry.path("ref").asString(), journal.id());
                }
            } catch (DraftException e) {
                Map<String, Object> error = new LinkedHashMap<>();
                error.put("entry", index);
                error.put("code", e.error().code());
                errors.add(error);
            }
        }

        List<Map<String, Object>> wantErrors = new ArrayList<>();
        for (JsonNode raw : expected.path("errors")) {
            Map<String, Object> error = new LinkedHashMap<>();
            error.put("entry", raw.path("entry").asInt());
            error.put("code", raw.path("code").asString());
            wantErrors.add(error);
        }
        assertThat(errors).as("draft errors").isEqualTo(wantErrors);
        assertThat(journals).as("journal count").hasSize(expected.path("journalCount").asInt());

        LedgerProjection ledger = new LedgerProjection(chart, journals.values());
        expected.path("balances").properties().forEach(e -> assertThat(ledger.displayBalance(e.getKey(), false))
                .as("balance " + e.getKey()).isEqualTo(money(e.getValue(), currency)));
        expected.path("pendingBalances").properties().forEach(e -> assertThat(ledger.displayBalance(e.getKey(), true))
                .as("pending balance " + e.getKey()).isEqualTo(money(e.getValue(), currency)));
        assertThat(ledger.netWorth()).as("net worth").isEqualTo(money(expected.path("netWorth"), currency));

        JsonNode periods = input.path("periods");
        JsonNode expectedPeriods = expected.path("periods");
        for (int i = 0; i < periods.size(); i++) {
            LocalDate from = LocalDate.parse(periods.get(i).path("start").asString());
            LocalDate to = LocalDate.parse(periods.get(i).path("end").asString());
            JsonNode want = expectedPeriods.get(i);
            assertThat(ledger.expenses(from, to)).as("expenses period " + i)
                    .isEqualTo(money(want.path("expenses"), currency));
            assertThat(ledger.income(from, to)).as("income period " + i)
                    .isEqualTo(money(want.path("income"), currency));
            if (want.hasNonNull("pendingExpenses")) {
                assertThat(ledger.pendingExpenses(from, to)).as("pending expenses period " + i)
                        .isEqualTo(money(want.path("pendingExpenses"), currency));
            }
        }
        if (!periods.isEmpty()) {
            LocalDate from = LocalDate.parse(periods.get(0).path("start").asString());
            LocalDate to = LocalDate.parse(periods.get(0).path("end").asString());
            expected.path("categories").properties().forEach(e -> assertThat(ledger.categoryNet(e.getKey(), from, to))
                    .as("category " + e.getKey()).isEqualTo(money(e.getValue(), currency)));
        }
    }

    private static TransactionDraft draft(JsonNode entry, CurrencyUnit currency, Map<String, String> refs) {
        List<Split> splits = new ArrayList<>();
        for (JsonNode split : entry.path("splits")) {
            splits.add(new Split(split.path("category").asString(), money(split.path("amount"), currency)));
        }
        String refundOf = entry.hasNonNull("refundOf") ? refs.get(entry.path("refundOf").asString()) : null;
        return TransactionDraft.builder(TransactionType.fromWire(entry.path("type").asString()),
                        entry.path("account").asString(), money(entry.path("amount"), currency),
                        LocalDate.parse(entry.path("date").asString()))
                .counterAccountId(entry.hasNonNull("to") ? entry.path("to").asString() : null)
                .status(JournalStatus.fromWire(entry.path("status").asString("posted")))
                .refundOf(refundOf)
                .splits(splits)
                .build();
    }

    private static Money money(JsonNode text, CurrencyUnit currency) {
        return Money.parse(text.asString(), currency);
    }
}
