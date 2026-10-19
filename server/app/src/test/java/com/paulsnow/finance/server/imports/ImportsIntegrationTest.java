package com.paulsnow.finance.server.imports;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * CSV import preview and commit (IMP 01-03): totals and row errors,
 * repeatable commits (A12), identical same-day purchases (A11), overlapping
 * statements, match candidates, workspace scoping and rollback.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ImportsIntegrationTest extends IntegrationTestSupport {

    @Autowired
    JdbcClient jdbc;

    record Setup(Actor actor, String bank, String spending, String earning) {
    }

    @Test
    void previewsTotalsAndRowErrorsBeforeCommitting() throws Exception {
        Setup s = setup();
        JsonNode preview = preview(s, s.bank(), """
                Date,Description,Amount
                01/07/2026,Grocer,-63.25
                02/07/2026,Salary,3123.45
                31/02/2026,Impossible,-1.00
                03/07/2026,Cafe,-4.50
                """);
        assertThat(preview.path("status").asString()).isEqualTo("previewed");
        assertThat(preview.path("rowCount").asInt()).isEqualTo(4);
        assertThat(preview.path("errorCount").asInt()).isEqualTo(1);
        assertThat(preview.path("newCount").asInt()).isEqualTo(3);
        assertThat(preview.path("totals").path("inflowMinor").asLong()).isEqualTo(312345);
        assertThat(preview.path("totals").path("outflowMinor").asLong()).isEqualTo(6775);
        assertThat(preview.path("totals").path("netMinor").asLong()).isEqualTo(305570);
        JsonNode bad = preview.path("rows").get(2);
        assertThat(bad.path("rowNumber").asInt()).isEqualTo(4);
        assertThat(bad.path("status").asString()).isEqualTo("error");
        assertThat(bad.path("errorCode").asString()).isEqualTo("BAD_DATE");
        assertThat(journalCount(s)).isZero();
        assertThat(jdbc.sql("select count(*) from import_row where batch_id = ?::uuid")
                .param(preview.path("batchId").asString()).query(Long.class).single()).isEqualTo(4);
    }

    @Test
    void a11AndA12ReimportingTheSameStatementAddsNoJournalsAndKeepsIdenticalPurchases() throws Exception {
        Setup s = setup();
        String csv = """
                Date,Description,Amount
                05/07/2026,Coffee Cart,-4.50
                05/07/2026,Coffee Cart,-4.50
                06/07/2026,Pay,2000.00
                """;
        JsonNode preview = preview(s, s.bank(), csv);
        String batchId = preview.path("batchId").asString();
        assertThat(preview.path("rows").get(0).path("fingerprint").asString()).endsWith("#1");
        assertThat(preview.path("rows").get(1).path("fingerprint").asString()).endsWith("#2");

        JsonNode committed = commit(s, batchId, null);
        assertThat(committed.path("status").asString()).isEqualTo("committed");
        assertThat(committed.path("result").path("imported").asInt()).isEqualTo(3);
        assertThat(journalCount(s)).isEqualTo(3);
        assertThat(balance(s, s.bank())).isEqualTo(200000 - 900);

        JsonNode again = commit(s, batchId, null);
        assertThat(again.path("result")).isEqualTo(committed.path("result"));
        JsonNode repreview = preview(s, s.bank(), csv);
        assertThat(repreview.path("batchId").asString()).isEqualTo(batchId);
        assertThat(repreview.path("status").asString()).isEqualTo("committed");
        commit(s, batchId, null);
        assertThat(journalCount(s)).isEqualTo(3);

        JsonNode batch = json.readTree(mvc.perform(get("/v1/imports/" + batchId).with(user(s.actor().subject()))
                        .header("X-Workspace-Id", s.actor().workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        for (JsonNode row : batch.path("rows")) {
            assertThat(row.path("status").asString()).isEqualTo("committed");
            assertThat(row.path("journalId").asString()).isNotBlank();
        }
    }

    @Test
    void flagsRowsAlreadyImportedFromAnOverlappingStatement() throws Exception {
        Setup s = setup();
        commit(s, preview(s, s.bank(), """
                Date,Description,Amount
                01/07/2026,Rent,-1500.00
                02/07/2026,Grocer,-80.00
                """).path("batchId").asString(), null);
        JsonNode overlap = preview(s, s.bank(), """
                Date,Description,Amount
                02/07/2026,Grocer,-80.00
                03/07/2026,Fuel,-60.00
                """);
        assertThat(texts(overlap.path("rows"), "status")).containsExactly("duplicate", "new");
        assertThat(overlap.path("duplicateCount").asInt()).isEqualTo(1);
        JsonNode result = commit(s, overlap.path("batchId").asString(), null);
        assertThat(result.path("result").path("imported").asInt()).isEqualTo(1);
        assertThat(result.path("result").path("duplicates").asInt()).isEqualTo(1);
        assertThat(journalCount(s)).isEqualTo(3);
    }

    @Test
    void importsADuplicateOnlyWhenTheUserSaysSo() throws Exception {
        Setup s = setup();
        String first = """
                Date,Description,Amount
                02/07/2026,Grocer,-80.00
                """;
        commit(s, preview(s, s.bank(), first).path("batchId").asString(), null);
        JsonNode second = preview(s, s.bank(), first + "03/07/2026,Fuel,-60.00\n");
        JsonNode result = commit(s, second.path("batchId").asString(), Map.of("2", "import", "3", "skip"));
        assertThat(result.path("result").path("imported").asInt()).isEqualTo(1);
        assertThat(result.path("result").path("skipped").asInt()).isEqualTo(1);
        assertThat(journalCount(s)).isEqualTo(2);
    }

    @Test
    void proposesTransfersAndExistingEntriesWithoutActingOnThem() throws Exception {
        Setup s = setup();
        String savings = createAccount(s.actor(), "savings");
        submitOne(s.actor(), postJournal(s.actor(), journal(Ids.newId(), "transfer", "posted", LocalDate.of(2026, 7, 2),
                List.of(Map.entry("system:transfer-clearing", 5000L), Map.entry(savings, -5000L)), savings, 5000), 0));
        submitOne(s.actor(), postJournal(s.actor(), expenseJournal(Ids.newId(), s.bank(), s.spending(), 6325,
                "posted"), 0));
        JsonNode preview = preview(s, s.bank(), """
                Date,Description,Amount
                03/07/2026,From savings,50.00
                01/07/2026,Grocer,-63.25
                """);
        assertThat(texts(preview.path("rows").get(0).path("matches"), "kind")).containsExactly("transfer");
        assertThat(texts(preview.path("rows").get(1).path("matches"), "kind")).containsExactly("existingEntry");
        assertThat(preview.path("rows").get(1).path("status").asString()).isEqualTo("new");
        assertThat(journalCount(s)).isEqualTo(2);
    }

    @Test
    void reportsAGapSinceThePreviousStatement() throws Exception {
        Setup s = setup();
        commit(s, preview(s, s.bank(), "Date,Description,Amount\n01/07/2026,Rent,-1.00\n").path("batchId")
                .asString(), null);
        JsonNode later = preview(s, s.bank(), "Date,Description,Amount\n20/07/2026,Fuel,-2.00\n");
        assertThat(later.path("dateGap").path("from").asString()).isEqualTo("2026-07-02");
        assertThat(later.path("dateGap").path("to").asString()).isEqualTo("2026-07-19");
    }

    @Test
    void keepsBatchesInsideTheirWorkspace() throws Exception {
        Setup s = setup();
        String batchId = preview(s, s.bank(), "Date,Description,Amount\n01/07/2026,Rent,-1.00\n")
                .path("batchId").asString();
        Actor stranger = newActor();
        mvc.perform(get("/v1/imports/" + batchId).with(user(stranger.subject()))
                        .header("X-Workspace-Id", stranger.workspaceId().toString()))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("IMPORT_NOT_FOUND"));
        mvc.perform(post("/v1/imports/" + batchId + "/commit").with(user(stranger.subject()))
                        .header("X-Workspace-Id", stranger.workspaceId().toString()))
                .andExpect(status().isNotFound());
    }

    @Test
    void validatesTheAccountCategoriesAndMapping() throws Exception {
        Setup s = setup();
        previewExpecting(s, Ids.newId(), s.spending(), s.earning(), "Date,Description,Amount\n", 400,
                "UNKNOWN_ACCOUNT");
        previewExpecting(s, s.bank(), s.earning(), s.earning(), "Date,Description,Amount\n", 400,
                "WRONG_CATEGORY_KIND");
        previewExpecting(s, s.bank(), s.spending(), s.earning(), "When,What,HowMuch\n01/07/2026,x,-1.00\n", 400,
                "COLUMN_NOT_FOUND");
    }

    @Test
    void rollsBackABatchButHoldsEntriesEditedSince() throws Exception {
        Setup s = setup();
        JsonNode committed = commit(s, preview(s, s.bank(), """
                Date,Description,Amount
                01/07/2026,Rent,-1500.00
                02/07/2026,Grocer,-80.00
                """).path("batchId").asString(), null);
        String batchId = committed.path("batchId").asString();
        String editedJournal = committed.path("rows").get(1).path("journalId").asString();
        JsonNode stored = json.readTree(mvc.perform(get("/v1/sync/changes").with(user(s.actor().subject()))
                        .header("X-Device-Id", s.actor().deviceId().toString()))
                .andReturn().getResponse().getContentAsString());
        ObjectNode original = null;
        for (JsonNode change : stored.path("changes")) {
            if (change.path("entityId").asString().equals(editedJournal)) {
                original = (ObjectNode) change.path("data");
            }
        }
        assertThat(original).isNotNull();
        ObjectNode reversal = original.deepCopy();
        reversal.put("id", Ids.newId());
        reversal.put("type", "reversal");
        reversal.put("reversalOf", editedJournal);
        for (JsonNode posting : reversal.path("postings")) {
            ((ObjectNode) posting).put("amountMinor", -posting.path("amountMinor").asLong());
        }
        ObjectNode payload = json.createObjectNode().put("originalId", editedJournal);
        payload.set("reversal", reversal);
        payload.putNull("replacement");
        assertThat(submitOne(s.actor(), command(s.actor(), "journal.correct", "journal", editedJournal, 1, payload))
                .path("status").asString()).isEqualTo("applied");

        JsonNode rolledBack = json.readTree(mvc.perform(post("/v1/imports/" + batchId + "/rollback")
                        .with(user(s.actor().subject()))
                        .header("X-Workspace-Id", s.actor().workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(rolledBack.path("status").asString()).isEqualTo("rolled_back");
        assertThat(rolledBack.path("result").path("rollback").path("reversed").asInt()).isEqualTo(1);
        assertThat(rolledBack.path("result").path("rollback").path("heldForReview").get(0).path("rowNumber").asInt())
                .isEqualTo(3);
        assertThat(balance(s, s.bank())).isZero();
    }

    // Helpers ------------------------------------------------------------------

    private Setup setup() throws Exception {
        Actor actor = newActor();
        return new Setup(actor, createAccount(actor, "transaction"), createCategory(actor, "expense"),
                createCategory(actor, "income"));
    }

    private JsonNode preview(Setup s, String account, String csv) throws Exception {
        return json.readTree(mvc.perform(post("/v1/imports/preview").with(user(s.actor().subject()))
                        .header("X-Workspace-Id", s.actor().workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(request(account, s.spending(), s.earning(), csv))))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    private void previewExpecting(Setup s, String account, String outflow, String inflow, String csv, int status,
            String error) throws Exception {
        mvc.perform(post("/v1/imports/preview").with(user(s.actor().subject()))
                        .header("X-Workspace-Id", s.actor().workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(request(account, outflow, inflow, csv))))
                .andExpect(status().is(status)).andExpect(jsonPath("$.error").value(error));
    }

    private Map<String, Object> request(String account, String outflow, String inflow, String csv) {
        Map<String, Object> mapping = new LinkedHashMap<>();
        mapping.put("id", "m1");
        mapping.put("name", "Bank");
        mapping.put("accountId", account);
        mapping.put("dateColumn", "Date");
        mapping.put("descriptionColumn", "Description");
        mapping.put("amountColumn", "Amount");
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("fileName", "statement.csv");
        body.put("contentBase64", Base64.getEncoder().encodeToString(csv.getBytes(StandardCharsets.UTF_8)));
        body.put("mapping", mapping);
        body.put("outflowCategoryId", outflow);
        body.put("inflowCategoryId", inflow);
        return body;
    }

    private JsonNode commit(Setup s, String batchId, Map<String, String> decisions) throws Exception {
        var request = post("/v1/imports/" + batchId + "/commit").with(user(s.actor().subject()))
                .header("X-Workspace-Id", s.actor().workspaceId().toString());
        if (decisions != null) {
            request = request.contentType(MediaType.APPLICATION_JSON)
                    .content(json.writeValueAsString(Map.of("decisions", decisions)));
        }
        return json.readTree(mvc.perform(request).andExpect(status().isOk()).andReturn().getResponse()
                .getContentAsString());
    }

    private long journalCount(Setup s) {
        return jdbc.sql("select count(*) from ledger_journal where workspace_id = ? and type <> 'reversal' "
                        + "and status = 'posted'")
                .param(s.actor().workspaceId()).query(Long.class).single();
    }

    private long balance(Setup s, String account) {
        return jdbc.sql("select coalesce(sum(p.amount_minor), 0) from ledger_posting p join ledger_journal j "
                        + "on j.id = p.journal_id where p.workspace_id = ? and p.account = ? "
                        + "and j.status in ('posted', 'reversed')")
                .params(s.actor().workspaceId(), account).query(Long.class).single();
    }

    private static List<String> texts(JsonNode array, String field) {
        List<String> values = new ArrayList<>();
        array.forEach(v -> values.add(v.path(field).asString()));
        return values;
    }
}
