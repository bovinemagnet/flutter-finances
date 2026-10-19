package com.paulsnow.finance.server.reports;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.HouseholdSupport;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * Report endpoints (REP 01, REP 04): the shared report definitions computed
 * over canonical journals, restricted to what the calling member may see.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ReportsIntegrationTest extends HouseholdSupport {

    /** A small ledger: salary, groceries, a transfer to savings and a pending purchase. */
    private record Ledger(String bank, String savings, String groceries, String salary, String pay, String shop,
            String move, String pending) {
    }

    private Ledger ledger(Actor owner) throws Exception {
        String bank = createAccount(owner, "transaction");
        String savings = createAccount(owner, "savings");
        String groceries = createCategory(owner, "expense");
        String salary = createCategory(owner, "income");
        String pay = Ids.newId();
        String shop = Ids.newId();
        String move = Ids.newId();
        String pending = Ids.newId();
        JsonNode results = submit(owner,
                postJournal(owner, payee(journal(pay, "income", "posted", LocalDate.of(2026, 7, 1),
                        List.of(Map.entry(bank, 300_000L), Map.entry(salary, -300_000L)), bank, 300_000), "Employer"),
                        0),
                postJournal(owner, journal(shop, "expense", "posted", LocalDate.of(2026, 7, 5),
                        List.of(Map.entry(groceries, 10_000L), Map.entry(bank, -10_000L)), bank, 10_000), 0),
                postJournal(owner, journal(move, "transfer", "posted", LocalDate.of(2026, 7, 15),
                        List.of(Map.entry(savings, 50_000L), Map.entry(bank, -50_000L)), bank, 50_000), 0),
                postJournal(owner, journal(pending, "expense", "pending", LocalDate.of(2026, 8, 4),
                        List.of(Map.entry(groceries, 99_900L), Map.entry(bank, -99_900L)), bank, 99_900), 0));
        results.forEach(r -> assertThat(r.path("status").asString()).isEqualTo("applied"));
        return new Ledger(bank, savings, groceries, salary, pay, shop, move, pending);
    }

    @Test
    void incomeVsExpensesForAFinancialYearCountsPostedIncomeAndSpendingButNotTransfers() throws Exception {
        Actor owner = newActor();
        Ledger l = ledger(owner);

        JsonNode report = report(owner, "income-vs-expenses", "financialYear", "2026");

        assertThat(report.path("kind").asString()).isEqualTo("income-vs-expenses");
        assertThat(report.path("complete").asBoolean()).isTrue();
        assertThat(report.path("currency").asString()).isEqualTo("AUD");
        assertThat(report.path("currencyExponent").asInt()).isEqualTo(2);
        assertThat(report.path("range").path("start").asString()).isEqualTo("2026-07-01");
        assertThat(report.path("range").path("end").asString()).isEqualTo("2027-06-30");
        assertThat(report.path("range").path("label").asString()).isEqualTo("FY2026-27");
        assertThat(report.path("rows")).hasSize(12);
        JsonNode july = report.path("rows").get(0);
        assertThat(july.path("key").asString()).isEqualTo("2026-07");
        assertThat(july.path("amounts").path("income").asLong()).isEqualTo(300_000);
        assertThat(july.path("amounts").path("expenses").asLong()).isEqualTo(10_000);
        assertThat(july.path("amounts").path("net").asLong()).isEqualTo(290_000);
        assertThat(strings(july.path("journalIds"))).containsExactly(l.pay(), l.shop());
        // The pending purchase is not in the posted ledger.
        assertThat(report.path("rows").get(1).path("amounts").path("expenses").asLong()).isZero();
    }

    @Test
    void spendingByCategoryAndPayeeUseACustomRange() throws Exception {
        Actor owner = newActor();
        Ledger l = ledger(owner);

        JsonNode byCategory = report(owner, "spending-by-category", "from", "2026-07-01", "to", "2026-07-31");
        assertThat(byCategory.path("rows")).hasSize(1);
        assertThat(byCategory.path("rows").get(0).path("key").asString()).isEqualTo(l.groceries());
        assertThat(byCategory.path("rows").get(0).path("amounts").path("spending").asLong()).isEqualTo(10_000);
        assertThat(strings(byCategory.path("rows").get(0).path("journalIds"))).containsExactly(l.shop());

        JsonNode byPayee = report(owner, "spending-by-payee", "calendarYear", "2026");
        assertThat(byPayee.path("rows").get(0).path("key").asString()).isEqualTo("Grocer");
        assertThat(byPayee.path("range").path("label").asString()).isEqualTo("2026-01-01..2026-12-31");
    }

    @Test
    void accountBalancesNetWorthAndCashFlow() throws Exception {
        Actor owner = newActor();
        Ledger l = ledger(owner);

        JsonNode balances = report(owner, "account-balances", "asOf", "2026-07-10");
        assertThat(balances.path("asOf").asString()).isEqualTo("2026-07-10");
        assertThat(balances.path("range").isNull()).isTrue();
        assertThat(row(balances, l.bank()).path("amounts").path("balance").asLong()).isEqualTo(290_000);
        assertThat(row(balances, l.savings()).path("amounts").path("balance").asLong()).isZero();
        assertThat(strings(row(balances, l.bank()).path("journalIds"))).containsExactly(l.pay(), l.shop());

        JsonNode netWorth = report(owner, "net-worth-history", "from", "2026-07-01", "to", "2026-08-31");
        assertThat(netWorth.path("rows")).hasSize(2);
        assertThat(netWorth.path("rows").get(0).path("key").asString()).isEqualTo("2026-07-31");
        assertThat(netWorth.path("rows").get(0).path("amounts").path("netWorth").asLong()).isEqualTo(290_000);

        JsonNode cashFlow = json.readTree(mvc.perform(get("/v1/reports/cash-flow").with(user(owner.subject()))
                        .header("X-Workspace-Id", owner.workspaceId().toString())
                        .param("calendarYear", "2026").param("accountIds", l.bank(), l.savings()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(row(cashFlow, "inflows").path("amounts").path("amount").asLong()).isEqualTo(300_000);
        assertThat(row(cashFlow, "outflows").path("amounts").path("amount").asLong()).isEqualTo(10_000);
        assertThat(row(cashFlow, "internalTransfers").path("amounts").path("amount").asLong()).isEqualTo(50_000);
        assertThat(strings(row(cashFlow, "internalTransfers").path("journalIds"))).containsExactly(l.move());
    }

    @Test
    void aHouseholdMemberOnlySeesSharedAccountsAndTheirJournals() throws Exception {
        Actor owner = newActor();
        Ledger l = ledger(owner);
        String joint = Ids.newId();
        assertThat(submitOne(owner, upsert(owner, "account", joint, 0,
                Map.of("name", "Joint", "type", "transaction", "sharing", "shared"))).path("status").asString())
                .isEqualTo("applied");
        String jointShop = Ids.newId();
        assertThat(submitOne(owner, postJournal(owner, journal(jointShop, "expense", "posted",
                LocalDate.of(2026, 7, 6), List.of(Map.entry(l.groceries(), 4_000L), Map.entry(joint, -4_000L)),
                joint, 4_000), 0)).path("status").asString()).isEqualTo("applied");
        Actor member = join(owner, "member");
        Actor viewer = join(owner, "viewer");

        for (Actor reader : List.of(member, viewer)) {
            JsonNode spending = report(reader, "spending-by-category", "financialYear", "2026");
            assertThat(spending.path("complete").asBoolean()).isFalse();
            assertThat(spending.path("rows")).hasSize(1);
            assertThat(spending.path("rows").get(0).path("amounts").path("spending").asLong()).isEqualTo(4_000);
            assertThat(strings(spending.path("rows").get(0).path("journalIds"))).containsExactly(jointShop);

            JsonNode balances = report(reader, "account-balances");
            assertThat(keys(balances)).containsExactly(joint);
        }
        // The owner sees everything.
        JsonNode ownerView = report(owner, "spending-by-category", "financialYear", "2026");
        assertThat(ownerView.path("complete").asBoolean()).isTrue();
        assertThat(ownerView.path("rows").get(0).path("amounts").path("spending").asLong()).isEqualTo(14_000);

        // A private account is indistinguishable from one that does not exist.
        for (String account : List.of(l.bank(), Ids.newId())) {
            mvc.perform(get("/v1/reports/cash-flow").with(user(member.subject()))
                            .header("X-Device-Id", member.deviceId().toString())
                            .param("calendarYear", "2026").param("accountIds", account))
                    .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("UNKNOWN_ACCOUNT"));
        }
    }

    @Test
    void rejectsUnknownKindsAndMalformedPeriods() throws Exception {
        Actor owner = newActor();
        expectError(owner, get("/v1/reports/budget-forecast").param("calendarYear", "2026"), 404, "UNKNOWN_REPORT");
        expectError(owner, get("/v1/reports/income-vs-expenses"), 400, "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/income-vs-expenses").param("from", "2026-07-01"), 400, "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/income-vs-expenses").param("from", "2026-07-01")
                .param("to", "2026-06-30"), 400, "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/income-vs-expenses").param("calendarYear", "2026")
                .param("financialYear", "2026"), 400, "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/income-vs-expenses").param("from", "1 July"), 400, "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/account-balances").param("calendarYear", "2026"), 400,
                "INVALID_PERIOD");
        expectError(owner, get("/v1/reports/cash-flow").param("calendarYear", "2026"), 400, "INVALID_REQUEST");
        mvc.perform(get("/v1/reports/income-vs-expenses").param("calendarYear", "2026")
                        .with(user(newSubject())).header("X-Workspace-Id", owner.workspaceId().toString()))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("WORKSPACE_NOT_FOUND"));
    }

    private void expectError(Actor actor, MockHttpServletRequestBuilder request, int status, String code)
            throws Exception {
        mvc.perform(request.with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().is(status)).andExpect(jsonPath("$.error").value(code));
    }

    private JsonNode report(Actor actor, String kind, String... params) throws Exception {
        MockHttpServletRequestBuilder request = get("/v1/reports/" + kind).with(user(actor.subject()))
                .header("X-Device-Id", actor.deviceId().toString());
        for (int i = 0; i < params.length; i += 2) {
            request.param(params[i], params[i + 1]);
        }
        return json.readTree(mvc.perform(request).andExpect(status().isOk()).andReturn().getResponse()
                .getContentAsString());
    }

    private static ObjectNode payee(ObjectNode journal, String payee) {
        journal.put("payee", payee);
        return journal;
    }

    private static JsonNode row(JsonNode report, String key) {
        for (JsonNode row : report.path("rows")) {
            if (row.path("key").asString().equals(key)) {
                return row;
            }
        }
        throw new AssertionError("No row " + key + " in " + report);
    }

    private static List<String> keys(JsonNode report) {
        List<String> keys = new ArrayList<>();
        report.path("rows").forEach(r -> keys.add(r.path("key").asString()));
        return keys;
    }

    private static List<String> strings(JsonNode array) {
        List<String> values = new ArrayList<>();
        array.forEach(v -> values.add(v.asString()));
        return values;
    }
}
