package com.paulsnow.finance.server.sync;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * Command intake: idempotency (A09), journal validation, revisions,
 * conflicts (A10) and field-level metadata merge (SYNC 02, SYNC 03).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class SyncCommandsIntegrationTest extends IntegrationTestSupport {

    @Autowired
    JdbcClient jdbc;

    @Test
    void appliesAnAccountCreationWithRevisionAndCursor() throws Exception {
        Actor actor = newActor();
        String id = Ids.newId();
        JsonNode result = submitOne(actor, upsert(actor, "account", id, 0,
                Map.of("name", "Everyday", "type", "transaction")));
        assertThat(result.path("status").asString()).isEqualTo("applied");
        assertThat(result.path("revision").asLong()).isEqualTo(1);
        assertThat(result.path("cursor").asString()).isNotBlank();
        assertThat(result.path("errors")).isEmpty();
    }

    @Test
    void a09RetryAfterLostResponseReturnsTheOriginalResultAndAppliesNothingTwice() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        ObjectNode command = postJournal(actor, expenseJournal(Ids.newId(), bank, groceries, 6325, "posted"), 0);

        JsonNode first = submitOne(actor, command);
        JsonNode retry = submitOne(actor, command);
        JsonNode retryInBatch = submit(actor, command, command);

        assertThat(first.path("status").asString()).isEqualTo("applied");
        assertThat(retry.path("status").asString()).isEqualTo("previously_applied");
        assertThat(retry.path("revision")).isEqualTo(first.path("revision"));
        assertThat(retry.path("cursor")).isEqualTo(first.path("cursor"));
        assertThat(retryInBatch.get(0).path("status").asString()).isEqualTo("previously_applied");
        assertThat(retryInBatch.get(1).path("status").asString()).isEqualTo("previously_applied");
        assertThat(journalCount(actor)).isEqualTo(1);
        assertThat(bankBalance(actor, bank)).isEqualTo(-6325);
        assertThat(changeCount(actor, command.path("entityId").asString())).isEqualTo(1);
    }

    @Test
    void rejectsACommandIdReusedWithADifferentPayload() throws Exception {
        Actor actor = newActor();
        String id = Ids.newId();
        ObjectNode original = upsert(actor, "account", id, 0, Map.of("name", "A", "type", "transaction"));
        submitOne(actor, original);
        ObjectNode altered = original.deepCopy();
        ((ObjectNode) altered.path("payload").path("fields")).put("name", "B");
        JsonNode result = submitOne(actor, altered);
        assertThat(result.path("status").asString()).isEqualTo("validation_failed");
        assertThat(texts(result.path("errors"))).containsExactly("IDEMPOTENCY_KEY_REUSED");
    }

    @Test
    void reportsJournalValidationFailuresWithTheirCodes() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");

        ObjectNode unbalanced = journal(Ids.newId(), "expense", "posted", LocalDate.of(2026, 7, 1),
                List.of(Map.entry(groceries, 8000L), Map.entry(bank, -10347L)), bank, 10347);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, unbalanced, 0)))).containsExactly("UNBALANCED");

        ObjectNode wrongCurrency = expenseJournal(Ids.newId(), bank, groceries, 100, "posted");
        wrongCurrency.put("currency", "NZD");
        assertThat(errorsOf(submitOne(actor, postJournal(actor, wrongCurrency, 0))))
                .containsExactly("CURRENCY_MISMATCH");

        ObjectNode unknownAccount = expenseJournal(Ids.newId(), bank, Ids.newId(), 100, "posted");
        assertThat(errorsOf(submitOne(actor, postJournal(actor, unknownAccount, 0))))
                .containsExactly("UNKNOWN_LEDGER_ACCOUNT");

        ObjectNode unknownSystem = journal(Ids.newId(), "adjustment", "posted", LocalDate.of(2026, 7, 1),
                List.of(Map.entry(bank, 100L), Map.entry("system:made-up", -100L)), bank, 100);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, unknownSystem, 0))))
                .containsExactly("UNKNOWN_LEDGER_ACCOUNT");

        ObjectNode reversedStatus = expenseJournal(Ids.newId(), bank, groceries, 100, "reversed");
        assertThat(errorsOf(submitOne(actor, postJournal(actor, reversedStatus, 0))))
                .containsExactly("INVALID_STATUS");

        ObjectNode empty = journal(Ids.newId(), "expense", "posted", LocalDate.of(2026, 7, 1), List.of(), bank, 0);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, empty, 0)))).containsExactly("EMPTY");

        ObjectNode zero = journal(Ids.newId(), "expense", "posted", LocalDate.of(2026, 7, 1),
                List.of(Map.entry(groceries, 0L), Map.entry(bank, 0L)), bank, 0);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, zero, 0)))).containsExactly("ZERO_AMOUNT");

        ObjectNode huge = journal(Ids.newId(), "expense", "posted", LocalDate.of(2026, 7, 1),
                List.of(Map.entry(groceries, 1_000_000_000_000_000L), Map.entry(bank, -1_000_000_000_000_000L)),
                bank, 1);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, huge, 0)))).containsExactly("OUT_OF_RANGE");

        ObjectNode malformed = json.createObjectNode().put("id", Ids.newId());
        JsonNode result = submitOne(actor, postJournal(actor, malformed, 0));
        assertThat(errorsOf(result)).containsExactly("INVALID_JOURNAL");

        assertThat(journalCount(actor)).isZero();
    }

    @Test
    void keepsPostedJournalsImmutable() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        ObjectNode journal = expenseJournal(Ids.newId(), bank, groceries, 6325, "posted");
        submitOne(actor, postJournal(actor, journal, 0));

        ObjectNode edited = expenseJournal(journal.path("id").asString(), bank, groceries, 3625, "posted");
        assertThat(errorsOf(submitOne(actor, postJournal(actor, edited, 1))))
                .containsExactly("POSTED_JOURNAL_IMMUTABLE");
        assertThat(errorsOf(submitOne(actor, command(actor, "entity.delete", "journal",
                journal.path("id").asString(), 1, json.createObjectNode()))))
                .containsExactly("POSTED_JOURNAL_IMMUTABLE");
        assertThat(bankBalance(actor, bank)).isEqualTo(-6325);
    }

    @Test
    void replacesDraftsAndPendingJournalsOnlyFromTheCurrentRevision() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        String id = Ids.newId();
        assertThat(submitOne(actor, postJournal(actor, expenseJournal(id, bank, groceries, 500, "draft"), 0))
                .path("revision").asLong()).isEqualTo(1);

        JsonNode pending = submitOne(actor, postJournal(actor, expenseJournal(id, bank, groceries, 700, "pending"), 1));
        assertThat(pending.path("status").asString()).isEqualTo("applied");
        assertThat(pending.path("revision").asLong()).isEqualTo(2);

        JsonNode stale = submitOne(actor, postJournal(actor, expenseJournal(id, bank, groceries, 900, "posted"), 1));
        assertThat(stale.path("status").asString()).isEqualTo("conflict");
        assertThat(stale.path("conflict").path("serverRevision").asLong()).isEqualTo(2);
        assertThat(stale.path("conflict").path("serverState").path("status").asString()).isEqualTo("pending");
        assertThat(texts(stale.path("conflict").path("fields"))).contains("status", "amountMinor", "postings");

        JsonNode posted = submitOne(actor, postJournal(actor, expenseJournal(id, bank, groceries, 900, "posted"), 2));
        assertThat(posted.path("status").asString()).isEqualTo("applied");
        assertThat(bankBalance(actor, bank)).isEqualTo(-900);
    }

    @Test
    void a10TwoDevicesCorrectingTheSameAmountYieldOneAcceptedCorrectionAndOneConflict() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String bank = createAccount(phone, "transaction");
        String groceries = createCategory(phone, "expense");
        ObjectNode original = expenseJournal(Ids.newId(), bank, groceries, 6325, "posted");
        submitOne(phone, postJournal(phone, original, 0));

        // Both devices edit the amount offline, from revision 1.
        ObjectNode phoneCorrection = correction(phone, original, 1, 3625);
        ObjectNode tabletCorrection = correction(tablet, original, 1, 3600);

        JsonNode accepted = submitOne(phone, phoneCorrection);
        JsonNode rejected = submitOne(tablet, tabletCorrection);

        assertThat(accepted.path("status").asString()).isEqualTo("applied");
        assertThat(accepted.path("revision").asLong()).isEqualTo(2);
        assertThat(rejected.path("status").asString()).isEqualTo("conflict");
        assertThat(rejected.path("conflict").path("serverRevision").asLong()).isEqualTo(2);
        assertThat(rejected.path("conflict").path("serverState").path("status").asString()).isEqualTo("reversed");
        assertThat(bankBalance(phone, bank)).isEqualTo(-3625);

        // The tablet keeps its proposal, sees the phone's replacement in the
        // feed and resolves by correcting that replacement with a fresh command.
        String phoneReplacementId = phoneCorrection.path("payload").path("replacement").path("id").asString();
        JsonNode feed = changes(tablet, null);
        JsonNode replacement = null;
        for (JsonNode change : feed.path("changes")) {
            if (change.path("entityId").asString().equals(phoneReplacementId)) {
                replacement = change;
            }
        }
        assertThat(replacement).isNotNull();
        ObjectNode resolution = correction(tablet, (ObjectNode) replacement.path("data"),
                replacement.path("revision").asLong(), 3600);
        assertThat(submitOne(tablet, resolution).path("status").asString()).isEqualTo("applied");

        assertThat(bankBalance(phone, bank)).isEqualTo(-3600);
        assertThat(jdbc.sql("select count(*) from ledger_journal where workspace_id = ? and status = 'posted' "
                        + "and type <> 'reversal'")
                .param(phone.workspaceId()).query(Long.class).single()).isEqualTo(1);
        assertThat(jdbc.sql("select count(*) from (select journal_id from ledger_posting where workspace_id = ? "
                        + "group by journal_id having sum(amount_minor) <> 0) unbalanced")
                .param(phone.workspaceId()).query(Long.class).single()).isZero();
    }

    @Test
    void rejectsReversalsThatDoNotNegateTheOriginal() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        ObjectNode original = expenseJournal(Ids.newId(), bank, groceries, 6325, "posted");
        submitOne(actor, postJournal(actor, original, 0));
        ObjectNode bad = correction(actor, original, 1, 3625);
        ArrayNode postings = (ArrayNode) bad.path("payload").path("reversal").path("postings");
        ((ObjectNode) postings.get(0)).put("amountMinor", -6000);
        ((ObjectNode) postings.get(1)).put("amountMinor", 6000);
        JsonNode result = submitOne(actor, bad);
        assertThat(result.path("status").asString()).isEqualTo("validation_failed");
        assertThat(texts(result.path("errors"))).containsExactly("REVERSAL_MISMATCH");
        assertThat(bankBalance(actor, bank)).isEqualTo(-6325);
    }

    @Test
    void voidsAPostedJournalWithACorrectionWithoutReplacement() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        ObjectNode original = expenseJournal(Ids.newId(), bank, groceries, 6325, "posted");
        submitOne(actor, postJournal(actor, original, 0));
        ObjectNode voiding = correction(actor, original, 1, 0);
        ((ObjectNode) voiding.path("payload")).putNull("replacement");
        assertThat(submitOne(actor, voiding).path("status").asString()).isEqualTo("applied");
        assertThat(bankBalance(actor, bank)).isZero();
    }

    @Test
    void mergesIndependentMetadataFieldsAndConflictsOnTheSameField() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String id = Ids.newId();
        submitOne(phone, upsert(phone, "account", id, 0,
                Map.of("name", "Everyday", "type", "transaction", "includeInBudget", true)));

        assertThat(submitOne(phone, upsert(phone, "account", id, 1, Map.of("name", "Daily")))
                .path("revision").asLong()).isEqualTo(2);

        JsonNode merged = submitOne(tablet, upsert(tablet, "account", id, 1, Map.of("includeInBudget", false)));
        assertThat(merged.path("status").asString()).isEqualTo("applied");
        assertThat(merged.path("revision").asLong()).isEqualTo(3);

        JsonNode conflict = submitOne(tablet, upsert(tablet, "account", id, 1, Map.of("name", "Main")));
        assertThat(conflict.path("status").asString()).isEqualTo("conflict");
        assertThat(texts(conflict.path("conflict").path("fields"))).containsExactly("name");
        assertThat(conflict.path("conflict").path("serverRevision").asLong()).isEqualTo(3);
        assertThat(conflict.path("conflict").path("serverState").path("name").asString()).isEqualTo("Daily");
        assertThat(conflict.path("conflict").path("serverState").path("includeInBudget").asBoolean()).isFalse();

        JsonNode sameValue = submitOne(tablet, upsert(tablet, "account", id, 1, Map.of("name", "Daily")));
        assertThat(sameValue.path("status").asString()).isEqualTo("applied");
    }

    @Test
    void validatesAccountsAndCategoriesAndProtectsReferencedOnes() throws Exception {
        Actor actor = newActor();
        assertThat(errorsOf(submitOne(actor, upsert(actor, "account", Ids.newId(), 0, Map.of("name", "x")))))
                .containsExactly("MISSING_FIELD");
        assertThat(errorsOf(submitOne(actor, upsert(actor, "account", Ids.newId(), 0,
                Map.of("name", "x", "type", "spaceship"))))).containsExactly("INVALID_FIELD");
        assertThat(errorsOf(submitOne(actor, upsert(actor, "category", Ids.newId(), 0,
                Map.of("name", "x", "kind", "transfer"))))).containsExactly("INVALID_FIELD");

        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        assertThat(errorsOf(submitOne(actor, upsert(actor, "account", bank, 1, Map.of("type", "loan")))))
                .containsExactly("IMMUTABLE_FIELD");
        submitOne(actor, postJournal(actor, expenseJournal(Ids.newId(), bank, groceries, 100, "posted"), 0));
        assertThat(errorsOf(submitOne(actor, command(actor, "entity.delete", "category", groceries, 1,
                json.createObjectNode())))).containsExactly("ENTITY_IN_USE");

        String unused = createCategory(actor, "income");
        assertThat(submitOne(actor, command(actor, "entity.delete", "category", unused, 1,
                json.createObjectNode())).path("status").asString()).isEqualTo("applied");
        ObjectNode usesDeleted = journal(Ids.newId(), "income", "posted", LocalDate.of(2026, 7, 1),
                List.of(Map.entry(bank, 100L), Map.entry(unused, -100L)), bank, 100);
        assertThat(errorsOf(submitOne(actor, postJournal(actor, usesDeleted, 0))))
                .containsExactly("UNKNOWN_LEDGER_ACCOUNT");
    }

    @Test
    void storesOpaqueEntityTypesWithFieldMerge() throws Exception {
        Actor actor = newActor();
        String id = Ids.newId();
        JsonNode result = submitOne(actor, upsert(actor, "budgetAllocation", id, 0,
                Map.of("periodStart", "2026-07-01", "plannedMinor", 50000)));
        assertThat(result.path("status").asString()).isEqualTo("applied");
        assertThat(submitOne(actor, upsert(actor, "budgetAllocation", id, 1, Map.of("plannedMinor", 60000)))
                .path("revision").asLong()).isEqualTo(2);
        assertThat(errorsOf(submitOne(actor, upsert(actor, "account", id, 2, Map.of("name", "x")))))
                .containsExactly("ENTITY_TYPE_MISMATCH");
    }

    @Test
    void acceptsTheClientsDocumentAssetAndJournalAnnotationEntities() throws Exception {
        Actor actor = newActor();
        String journalId = Ids.newId();
        assertThat(submitOne(actor, upsert(actor, "journalAnnotation", journalId, 0,
                Map.of("payee", "Corner shop", "tags", List.of("weekly")))).path("status").asString())
                .isEqualTo("applied");
        assertThat(submitOne(actor, upsert(actor, "documentAsset", Ids.newId(), 0,
                Map.of("ownerId", Ids.newId(), "kind", "source", "contentType", "image/jpeg")))
                .path("status").asString()).isEqualTo("applied");
        assertThat(errorsOf(submitOne(actor, upsert(actor, "journal", Ids.newId(), 0, Map.of("payee", "x")))))
                .containsExactly("USE_JOURNAL_COMMANDS");
    }

    @Test
    void reevaluatesARejectedCommandWhenItIsRetriedWithANewBase() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String id = Ids.newId();
        submitOne(phone, upsert(phone, "account", id, 0, Map.of("name", "A", "type", "cash")));
        submitOne(phone, upsert(phone, "account", id, 1, Map.of("name", "B")));
        ObjectNode stale = upsert(tablet, "account", id, 1, Map.of("name", "C"));
        assertThat(submitOne(tablet, stale).path("status").asString()).isEqualTo("conflict");
        stale.put("baseRevision", 2);
        assertThat(submitOne(tablet, stale).path("status").asString()).isEqualTo("applied");
        assertThat(submitOne(tablet, stale).path("status").asString()).isEqualTo("previously_applied");
    }

    @Test
    void reportsDeletingAnAlreadyDeletedEntityAsAConflict() throws Exception {
        Actor actor = newActor();
        String id = createAccount(actor, "cash");
        submitOne(actor, command(actor, "entity.delete", "account", id, 1, json.createObjectNode()));
        JsonNode again = submitOne(actor, command(actor, "entity.delete", "account", id, 1, json.createObjectNode()));
        assertThat(again.path("status").asString()).isEqualTo("conflict");
        assertThat(again.path("conflict").path("serverState").isNull()).isTrue();
    }

    @Test
    void deniesCommandsForAnotherWorkspaceOrDevice() throws Exception {
        Actor actor = newActor();
        Actor other = newActor();
        ObjectNode foreign = upsert(actor, "account", Ids.newId(), 0, Map.of("name", "x", "type", "cash"));
        foreign.put("workspaceId", other.workspaceId().toString());
        assertThat(submitOne(actor, foreign).path("status").asString()).isEqualTo("permission_denied");

        ObjectNode otherDevice = upsert(actor, "account", Ids.newId(), 0, Map.of("name", "x", "type", "cash"));
        otherDevice.put("deviceId", other.deviceId().toString());
        assertThat(submitOne(actor, otherDevice).path("status").asString()).isEqualTo("permission_denied");
    }

    @Test
    void rejectsOversizedBatchesAndUnsupportedSchemas() throws Exception {
        Actor actor = newActor();
        ObjectNode body = json.createObjectNode();
        ArrayNode commands = body.putArray("commands");
        for (int i = 0; i < 501; i++) {
            commands.add(upsert(actor, "note", Ids.newId(), 0, Map.of("text", "n")));
        }
        mvc.perform(post("/v1/sync/commands").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("TOO_MANY_COMMANDS"));

        ObjectNode future = upsert(actor, "note", Ids.newId(), 0, Map.of("text", "n"));
        future.put("schemaVersion", 2);
        assertThat(errorsOf(submitOne(actor, future))).containsExactly("UNSUPPORTED_SCHEMA_VERSION");
        ObjectNode unknownType = upsert(actor, "note", Ids.newId(), 0, Map.of("text", "n"));
        unknownType.put("type", "entity.explode");
        assertThat(errorsOf(submitOne(actor, unknownType))).containsExactly("INVALID_COMMAND");
    }

    private ObjectNode correction(Actor actor, ObjectNode original, long baseRevision, long newAmount) {
        String originalId = original.path("id").asString();
        ObjectNode reversal = original.deepCopy();
        reversal.put("id", Ids.newId());
        reversal.put("type", "reversal");
        reversal.put("status", "posted");
        reversal.put("reversalOf", originalId);
        reversal.putNull("replaces");
        for (JsonNode posting : reversal.path("postings")) {
            ((ObjectNode) posting).put("amountMinor", -posting.path("amountMinor").asLong());
        }
        String account = original.path("accountId").asString();
        String category = null;
        for (JsonNode posting : original.path("postings")) {
            if (!posting.path("account").asString().equals(account)) {
                category = posting.path("account").asString();
            }
        }
        ObjectNode replacement = expenseJournal(Ids.newId(), account, category, newAmount, "posted");
        replacement.put("replaces", originalId);
        ObjectNode payload = json.createObjectNode();
        payload.put("originalId", originalId);
        payload.set("reversal", reversal);
        payload.set("replacement", replacement);
        return command(actor, "journal.correct", "journal", originalId, baseRevision, payload);
    }

    private long journalCount(Actor actor) {
        return jdbc.sql("select count(*) from ledger_journal where workspace_id = ?").param(actor.workspaceId())
                .query(Long.class).single();
    }

    private long bankBalance(Actor actor, String account) {
        return jdbc.sql("select coalesce(sum(p.amount_minor), 0) from ledger_posting p join ledger_journal j "
                        + "on j.id = p.journal_id where p.workspace_id = ? and p.account = ? "
                        + "and j.status in ('posted', 'reversed')")
                .params(actor.workspaceId(), account).query(Long.class).single();
    }

    private long changeCount(Actor actor, String entityId) {
        return jdbc.sql("select count(*) from sync_change where workspace_id = ? and entity_id = ?")
                .params(actor.workspaceId(), UUID.fromString(entityId)).query(Long.class).single();
    }

    private static List<String> errorsOf(JsonNode result) {
        assertThat(result.path("status").asString()).as(result.toString()).isEqualTo("validation_failed");
        return texts(result.path("errors"));
    }

    private static List<String> texts(JsonNode array) {
        List<String> values = new ArrayList<>();
        array.forEach(v -> values.add(v.asString()));
        return values;
    }
}
