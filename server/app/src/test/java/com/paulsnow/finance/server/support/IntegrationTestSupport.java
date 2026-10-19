package com.paulsnow.finance.server.support;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.AfterEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

import com.paulsnow.finance.core.ids.Ids;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * Base class for integration tests against real PostgreSQL and object
 * storage. Every test creates its own users and workspaces, so tests stay
 * independent without truncating tables.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import({ TestcontainersConfiguration.class, TestClockConfiguration.class })
public abstract class IntegrationTestSupport {

    @Autowired
    protected MockMvc mvc;

    @Autowired
    protected JsonMapper json;

    @Autowired
    protected MutableClock clock;

    /** A signed-in user with a workspace and a registered device. */
    public record Actor(String subject, UUID workspaceId, UUID deviceId) {
    }

    @AfterEach
    void resetClock() {
        clock.reset();
    }

    protected static RequestPostProcessor user(String subject) {
        return jwt().jwt(token -> token.subject(subject));
    }

    protected static String newSubject() {
        return "user-" + UUID.randomUUID();
    }

    /** Creates a user with a new AUD workspace and one registered device. */
    protected Actor newActor() throws Exception {
        String subject = newSubject();
        UUID workspaceId = createWorkspace(subject);
        return new Actor(subject, workspaceId, registerDevice(subject, workspaceId));
    }

    /** Registers another device for the same user and workspace. */
    protected Actor secondDevice(Actor actor) throws Exception {
        return new Actor(actor.subject(), actor.workspaceId(), registerDevice(actor.subject(), actor.workspaceId()));
    }

    protected UUID createWorkspace(String subject) throws Exception {
        String body = json.writeValueAsString(Map.of("name", "Household", "currency", "AUD",
                "timezone", "Australia/Brisbane"));
        String response = mvc.perform(post("/v1/workspaces").with(user(subject))
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        return UUID.fromString(json.readTree(response).path("id").asString());
    }

    protected UUID registerDevice(String subject, UUID workspaceId) throws Exception {
        UUID deviceId = Ids.newUuid();
        String body = json.writeValueAsString(Map.of("deviceId", deviceId.toString(),
                "workspaceId", workspaceId.toString(), "name", "Test phone", "platform", "android"));
        mvc.perform(post("/v1/devices").with(user(subject)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated());
        return deviceId;
    }

    /** Submits commands and returns the {@code results} array. */
    protected JsonNode submit(Actor actor, ObjectNode... commands) throws Exception {
        ObjectNode body = json.createObjectNode();
        ArrayNode array = body.putArray("commands");
        for (ObjectNode command : commands) {
            array.add(command);
        }
        String response = mvc.perform(post("/v1/sync/commands").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readTree(response).path("results");
    }

    /** Submits one command and returns its result. */
    protected JsonNode submitOne(Actor actor, ObjectNode command) throws Exception {
        return submit(actor, command).get(0);
    }

    /** Pulls one page of the change feed. */
    protected JsonNode changes(Actor actor, String cursor) throws Exception {
        String response = mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString())
                        .param("cursor", cursor == null ? "" : cursor))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readTree(response);
    }

    protected ObjectNode command(Actor actor, String type, String entityType, String entityId, long baseRevision,
            JsonNode payload) {
        ObjectNode command = json.createObjectNode();
        command.put("commandId", Ids.newId());
        command.put("workspaceId", actor.workspaceId().toString());
        command.put("deviceId", actor.deviceId().toString());
        command.put("type", type);
        command.put("entityType", entityType);
        command.put("entityId", entityId);
        command.put("baseRevision", baseRevision);
        command.put("schemaVersion", 1);
        command.set("payload", payload);
        return command;
    }

    /** An {@code entity.upsert} with the given changed fields. */
    protected ObjectNode upsert(Actor actor, String entityType, String entityId, long baseRevision,
            Map<String, Object> fields) {
        ObjectNode payload = json.createObjectNode();
        payload.set("fields", json.valueToTree(fields));
        return command(actor, "entity.upsert", entityType, entityId, baseRevision, payload);
    }

    /** Creates an account entity and returns its identifier. */
    protected String createAccount(Actor actor, String type) throws Exception {
        String id = Ids.newId();
        JsonNode result = submitOne(actor, upsert(actor, "account", id, 0, Map.of("name", "Account", "type", type)));
        if (!"applied".equals(result.path("status").asString())) {
            throw new AssertionError("Account not created: " + result);
        }
        return id;
    }

    /** Creates a category entity and returns its identifier. */
    protected String createCategory(Actor actor, String kind) throws Exception {
        String id = Ids.newId();
        JsonNode result = submitOne(actor, upsert(actor, "category", id, 0, Map.of("name", "Category", "kind", kind)));
        if (!"applied".equals(result.path("status").asString())) {
            throw new AssertionError("Category not created: " + result);
        }
        return id;
    }

    /** Journal JSON for a simple expense: category debit, account credit. */
    protected ObjectNode expenseJournal(String journalId, String accountId, String categoryId, long amountMinor,
            String status) {
        return journal(journalId, "expense", status, LocalDate.of(2026, 7, 1),
                List.of(Map.entry(categoryId, amountMinor), Map.entry(accountId, -amountMinor)), accountId,
                amountMinor);
    }

    protected ObjectNode journal(String journalId, String type, String status, LocalDate date,
            List<Map.Entry<String, Long>> postings, String accountId, long amountMinor) {
        ObjectNode journal = json.createObjectNode();
        journal.put("id", journalId);
        journal.put("type", type);
        journal.put("status", status);
        journal.put("effectiveDate", date.toString());
        journal.put("enteredAt", "2026-07-01T02:03:04Z");
        journal.put("currency", "AUD");
        ArrayNode lines = journal.putArray("postings");
        for (Map.Entry<String, Long> posting : postings) {
            lines.addObject().put("account", posting.getKey()).put("amountMinor", posting.getValue());
        }
        journal.put("accountId", accountId);
        journal.putNull("counterAccountId");
        journal.put("amountMinor", amountMinor);
        journal.put("payee", "Grocer");
        journal.putNull("notes");
        journal.putArray("tags");
        journal.putNull("refundOf");
        journal.putNull("reversalOf");
        journal.putNull("replaces");
        return journal;
    }

    /** A {@code journal.post} command for {@code journal}. */
    protected ObjectNode postJournal(Actor actor, ObjectNode journal, long baseRevision) {
        return command(actor, "journal.post", "journal", journal.path("id").asString(), baseRevision, journal);
    }
}
