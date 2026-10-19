package com.paulsnow.finance.server.bankfeeds;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.ResultActions;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;

/**
 * The bank feed adapter boundary (BANK 01-03) against the sandbox
 * provider: backfill, refresh, pending to posted, provider id changes,
 * reversals, reconnect, revoke, signed webhooks with replay protection,
 * rate limits with exponential backoff, encrypted tokens and proposals
 * that are never posted automatically.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Import(BankFeedsIntegrationTest.TestProviders.class)
@TestPropertySource(properties = {
        "finance.bank-feeds.sandbox.enabled=true",
        "finance.bank-feeds.token-key=" + BankFeedsIntegrationTest.TOKEN_KEY,
        "finance.bank-feeds.webhook-secrets.sandbox=" + BankFeedsIntegrationTest.WEBHOOK_SECRET,
        "finance.bank-feeds.refresh-base-backoff=1m",
        "finance.bank-feeds.refresh-max-backoff=1h" })
class BankFeedsIntegrationTest extends IntegrationTestSupport {

    static final String TOKEN_KEY = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
    static final String WEBHOOK_SECRET = "test-webhook-secret";

    static final AtomicInteger LIMITED_CALLS = new AtomicInteger();

    /** A provider that is rate limited twice, and one that needs a redirect. */
    @TestConfiguration(proxyBeanMethods = false)
    static class TestProviders {

        @Bean
        BankFeedProvider limitedProvider() {
            return new FixedProvider("limited") {
                @Override
                public TransactionPage fetchTransactions(ProviderTokens tokens, String accountId, String cursor) {
                    if (LIMITED_CALLS.incrementAndGet() <= 2) {
                        throw new RateLimitedException(Duration.ofSeconds(5));
                    }
                    return super.fetchTransactions(tokens, accountId, cursor);
                }
            };
        }

        @Bean
        BankFeedProvider redirectProvider() {
            return new FixedProvider("redirect-test") {
                @Override
                public ConsentStart startConsent(ConsentRequest request) {
                    return ConsentStart.redirect("https://consent.example.test/authorise?state=" + request.state());
                }

                @Override
                public ProviderGrant completeConsent(String state, String code) {
                    if (!"good-code".equals(code)) {
                        throw new ConsentRejectedException();
                    }
                    return super.startConsent(null).grant();
                }
            };
        }
    }

    /** Minimal provider: one account, one posted transaction. */
    static class FixedProvider implements BankFeedProvider {

        private final String id;

        FixedProvider(String id) {
            this.id = id;
        }

        @Override
        public String id() {
            return id;
        }

        @Override
        public ConsentStart startConsent(ConsentRequest request) {
            return ConsentStart.granted(new ProviderGrant("ref-" + UUID.randomUUID(), "fixed", "Fixed Bank",
                    new ProviderTokens("access-" + id, "refresh-" + id, Instant.now().plus(Duration.ofDays(1))),
                    Instant.now().plus(Duration.ofDays(365))));
        }

        @Override
        public ProviderGrant completeConsent(String state, String code) {
            throw new ConsentRejectedException();
        }

        @Override
        public List<ProviderAccount> listAccounts(ProviderTokens tokens) {
            return List.of(new ProviderAccount("acc-1", "Everyday", "transaction", "xx01"));
        }

        @Override
        public TransactionPage fetchTransactions(ProviderTokens tokens, String accountId, String cursor) {
            if (cursor != null) {
                return new TransactionPage(List.of(), cursor, false);
            }
            return new TransactionPage(List.of(new ProviderTransaction("fx-1", accountId, "posted", -1000, "AUD",
                    LocalDate.of(2026, 7, 1), "FIXED", null, null, null)), "1", false);
        }

        @Override
        public ConsentStatus consentStatus(ProviderTokens tokens) {
            return new ConsentStatus("active", Instant.now().plus(Duration.ofDays(365)));
        }

        @Override
        public ProviderTokens refresh(ProviderTokens tokens) {
            return tokens;
        }

        @Override
        public void revoke(ProviderTokens tokens) {
        }
    }

    @Autowired
    JobRunner jobs;

    @Autowired
    JdbcClient jdbc;

    @Test
    void backfillCreatesProviderRecordsAsOpenProposalsWithoutPostingAnything() throws Exception {
        Actor actor = newActor();
        JsonNode connection = connect(actor, "sandbox").andExpect(status().isCreated())
                .andExpect(jsonPath("$.consentStatus").value("active"))
                .andExpect(jsonPath("$.institution.name").value("Sandbox Bank"))
                .andExpect(jsonPath("$.sharedAccounts.length()").value(2))
                .andExpect(jsonPath("$.dataScope[0]").value("bank:accounts.basic:read"))
                .andExpect(jsonPath("$.purpose").value("Suggest entries from my bank transactions"))
                .andExpect(jsonPath("$.consentExpiresAt").isNotEmpty())
                .andExpect(jsonPath("$.consentUrl").doesNotExist())
                .andReturn().getResponse().getContentAsString().transform(json::readTree);
        String id = connection.path("id").asString();
        jobs.runUntilIdle();

        JsonNode proposals = proposals(actor, id);
        assertThat(proposals).hasSize(4);
        assertThat(texts(proposals, "providerTransactionId"))
                .containsExactlyInAnyOrder("sbx-t-001", "sbx-t-002", "sbx-p-003", "sbx-t-004");
        assertThat(texts(proposals, "proposalStatus")).containsOnly("open");
        JsonNode pending = find(proposals, "sbx-p-003");
        assertThat(pending.path("status").asString()).isEqualTo("pending");
        assertThat(pending.path("amountMinor").asLong()).isEqualTo(-450);

        JsonNode view = view(actor, id);
        assertThat(view.hasNonNull("lastSuccessfulRefreshAt")).isTrue();
        assertThat(view.path("stale").asBoolean()).isFalse();
        assertThat(view.path("error").isNull() || view.path("error").isMissingNode()).isTrue();

        // Provider records are kept apart from canonical journals.
        assertThat(jdbc.sql("select count(*) from ledger_journal where workspace_id = ?").param(actor.workspaceId())
                .query(Long.class).single()).isZero();
        assertThat(jdbc.sql("select count(*) from sync_entity where workspace_id = ?").param(actor.workspaceId())
                .query(Long.class).single()).isZero();

        // Tokens stay on the server, encrypted at rest.
        byte[] stored = jdbc.sql("select ciphertext from bank_feed_token where connection_id = ?::uuid").param(id)
                .query(byte[].class).single();
        assertThat(new String(stored, StandardCharsets.ISO_8859_1)).doesNotContain("sbx-at");
        assertThat(connection.toString()).doesNotContain("sbx-at").doesNotContain("sbx-rt");

        // Refreshing again with nothing new creates nothing.
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();
        assertThat(proposals(actor, id)).hasSize(4);
    }

    @Test
    void pendingToPostedIsLinkedByProviderIdsAndKeepsTheAcceptedJournal() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        JsonNode pending = find(proposals(actor, id), "sbx-p-003");

        String account = createAccount(actor, "transaction");
        String category = createCategory(actor, "expense");
        String journalId = Ids.newId();
        assertThat(submitOne(actor, postJournal(actor, expenseJournal(journalId, account, category, 450, "pending"),
                0)).path("status").asString()).isEqualTo("applied");
        decide(actor, id, pending.path("recordId").asString(), Map.of("decision", "accepted", "journalId",
                journalId)).andExpect(status().isOk()).andExpect(jsonPath("$.proposalStatus").value("accepted"));

        clock.advance(Duration.ofDays(1).plusHours(1));
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();

        JsonNode all = allProposals(actor, id);
        JsonNode settled = find(all, "sbx-p-003");
        JsonNode posted = find(all, "sbx-t-005");
        assertThat(posted.path("kind").asString()).isEqualTo("settles_pending");
        assertThat(posted.path("status").asString()).isEqualTo("posted");
        assertThat(posted.path("relatedRecordId").asString()).isEqualTo(settled.path("recordId").asString());
        assertThat(settled.path("settledByRecordId").asString()).isEqualTo(posted.path("recordId").asString());
        // The accepted pending proposal keeps its journal, so the client
        // settles that entry rather than adding a second purchase.
        assertThat(settled.path("proposalStatus").asString()).isEqualTo("accepted");
        assertThat(settled.path("journalId").asString()).isEqualTo(journalId);
        assertThat(texts(proposals(actor, id), "providerTransactionId")).contains("sbx-t-005", "sbx-t-006")
                .doesNotContain("sbx-p-003");
    }

    @Test
    void anUnacceptedPendingProposalIsSupersededWhenItPosts() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        clock.advance(Duration.ofDays(1).plusHours(1));
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();
        assertThat(find(allProposals(actor, id), "sbx-p-003").path("proposalStatus").asString())
                .isEqualTo("superseded");
    }

    @Test
    void providerIdChangesUpdateTheRecordAndReversalsAreLinked() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        JsonNode fuel = find(proposals(actor, id), "sbx-t-004");
        clock.advance(Duration.ofDays(2).plusHours(1));
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();

        JsonNode all = allProposals(actor, id);
        JsonNode renamed = find(all, "sbx-t-004b");
        assertThat(renamed.path("recordId").asString()).isEqualTo(fuel.path("recordId").asString());
        assertThat(texts(renamed.path("previousProviderTransactionIds"))).containsExactly("sbx-t-004");
        assertThat(texts(all, "providerTransactionId")).doesNotContain("sbx-t-004");

        JsonNode original = find(all, "sbx-t-006");
        JsonNode reversal = find(all, "sbx-t-007");
        assertThat(reversal.path("kind").asString()).isEqualTo("reversal");
        assertThat(reversal.path("relatedRecordId").asString()).isEqualTo(original.path("recordId").asString());
        assertThat(original.path("reversedByRecordId").asString()).isEqualTo(reversal.path("recordId").asString());
        assertThat(reversal.path("proposalStatus").asString()).isEqualTo("open");

        // Delivering the same changes again changes nothing.
        int before = all.size();
        jdbc.sql("update bank_feed_account set provider_cursor = null where connection_id = ?::uuid").param(id).update();
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();
        assertThat(allProposals(actor, id)).hasSize(before);
    }

    @Test
    void anExpiredConsentStopsCollectionUntilReconnected() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        clock.advance(Duration.ofDays(91));
        refresh(actor, id).andExpect(status().isAccepted());
        jobs.runUntilIdle();
        JsonNode expired = view(actor, id);
        assertThat(expired.path("consentStatus").asString()).isEqualTo("expired");
        refresh(actor, id).andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("CONSENT_EXPIRED"));

        mvc.perform(post("/v1/bank-feeds/connections/" + id + "/reconnect").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andExpect(jsonPath("$.consentStatus").value("active"));
        jobs.runUntilIdle();
        JsonNode reconnected = view(actor, id);
        assertThat(Instant.parse(reconnected.path("consentExpiresAt").asString()))
                .isAfter(Instant.parse(expired.path("consentExpiresAt").asString()));
        // The whole timeline is now available once, with no duplicates.
        assertThat(texts(allProposals(actor, id), "providerTransactionId")).doesNotHaveDuplicates()
                .contains("sbx-t-007");
    }

    @Test
    void revokingStopsCollectionAndDeletesTokens() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        clock.advance(Duration.ofDays(1).plusHours(1));
        refresh(actor, id).andExpect(status().isAccepted());

        mvc.perform(delete("/v1/bank-feeds/connections/" + id).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andExpect(jsonPath("$.consentStatus").value("revoked"));
        assertThat(jdbc.sql("select count(*) from bank_feed_token where connection_id = ?::uuid").param(id)
                .query(Long.class).single()).isZero();

        // The refresh queued before revocation collects nothing.
        jobs.runUntilIdle();
        assertThat(allProposals(actor, id)).hasSize(4);
        refresh(actor, id).andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("CONNECTION_REVOKED"));
        mvc.perform(post("/v1/bank-feeds/connections/" + id + "/reconnect").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("CONNECTION_REVOKED"));
    }

    @Test
    void webhooksAreVerifiedAndDeliveriesDeduplicated() throws Exception {
        Actor actor = newActor();
        String id = sandbox(actor);
        String reference = jdbc.sql("select provider_reference from bank_feed_connection where id = ?::uuid")
                .param(id).query(String.class).single();
        String body = json.writeValueAsString(Map.of("type", "transactions.updated", "connectionReference",
                reference));
        String delivery = UUID.randomUUID().toString();
        long now = clock.instant().getEpochSecond();

        webhook("sandbox", delivery, now, body, sign(delivery, now, body)).andExpect(status().isAccepted())
                .andExpect(jsonPath("$.status").value("accepted"));
        assertThat(queuedRefreshes(actor)).isEqualTo(1);

        // A replayed delivery is acknowledged and ignored.
        webhook("sandbox", delivery, now, body, sign(delivery, now, body)).andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("duplicate"));
        assertThat(queuedRefreshes(actor)).isEqualTo(1);

        String other = UUID.randomUUID().toString();
        webhook("sandbox", other, now, body, sign(other, now, body.replace("updated", "updatex")))
                .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error").value("INVALID_SIGNATURE"));
        webhook("sandbox", other, now, body, "v1=00").andExpect(status().isUnauthorized());
        long old = now - 3600;
        webhook("sandbox", other, old, body, sign(other, old, body)).andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error").value("TIMESTAMP_OUT_OF_TOLERANCE"));
        webhook("unknown", other, now, body, sign(other, now, body)).andExpect(status().isNotFound());
        assertThat(queuedRefreshes(actor)).isEqualTo(1);

        // The provider reports the consent revoked: collection stops.
        String revokedBody = json.writeValueAsString(Map.of("type", "consent.revoked", "connectionReference",
                reference));
        String third = UUID.randomUUID().toString();
        webhook("sandbox", third, now, revokedBody, sign(third, now, revokedBody)).andExpect(status().isAccepted());
        assertThat(view(actor, id).path("consentStatus").asString()).isEqualTo("revoked");
        assertThat(jdbc.sql("select count(*) from bank_feed_token where connection_id = ?::uuid").param(id)
                .query(Long.class).single()).isZero();
    }

    @Test
    void rateLimitsBackOffExponentiallyThenRecover() throws Exception {
        LIMITED_CALLS.set(0);
        Actor actor = newActor();
        String id = connect(actor, "limited").andExpect(status().isCreated()).andReturn().getResponse()
                .getContentAsString().transform(json::readTree).path("id").asString();
        jobs.runUntilIdle();
        JsonNode first = view(actor, id);
        assertThat(first.path("error").path("code").asString()).isEqualTo("RATE_LIMITED");
        Duration firstDelay = Duration.between(clock.instant(), Instant.parse(first.path("nextRefreshAt").asString()));
        assertThat(firstDelay).isBetween(Duration.ofSeconds(50), Duration.ofSeconds(61));

        clock.advance(Duration.ofSeconds(61));
        jobs.runUntilIdle();
        JsonNode second = view(actor, id);
        assertThat(second.path("error").path("code").asString()).isEqualTo("RATE_LIMITED");
        Duration secondDelay = Duration.between(clock.instant(),
                Instant.parse(second.path("nextRefreshAt").asString()));
        assertThat(secondDelay).isBetween(Duration.ofSeconds(110), Duration.ofSeconds(121));

        clock.advance(Duration.ofSeconds(121));
        jobs.runUntilIdle();
        JsonNode recovered = view(actor, id);
        assertThat(recovered.path("error").isNull() || recovered.path("error").isMissingNode()).isTrue();
        assertThat(recovered.hasNonNull("lastSuccessfulRefreshAt")).isTrue();
        assertThat(proposals(actor, id)).hasSize(1);
    }

    @Test
    void realProvidersReturnAConsentUrlAndCompleteWithTheMatchingState() throws Exception {
        Actor actor = newActor();
        JsonNode created = connect(actor, "redirect-test").andExpect(status().isCreated())
                .andExpect(jsonPath("$.consentStatus").value("pending"))
                .andReturn().getResponse().getContentAsString().transform(json::readTree);
        String id = created.path("id").asString();
        String url = created.path("consentUrl").asString();
        assertThat(url).startsWith("https://consent.example.test/authorise?state=");
        String state = url.substring(url.indexOf("state=") + 6);

        callback(actor, id, "wrong-state", "good-code").andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_CONSENT_STATE"));
        callback(actor, id, state, "bad-code").andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("CONSENT_REJECTED"));
        callback(actor, id, state, "good-code").andExpect(status().isOk())
                .andExpect(jsonPath("$.consentStatus").value("active"))
                .andExpect(jsonPath("$.institution.name").value("Fixed Bank"));
        jobs.runUntilIdle();
        assertThat(proposals(actor, id)).hasSize(1);
    }

    @Test
    void anotherWorkspaceCannotSeeOrChangeAConnection() throws Exception {
        Actor owner = newActor();
        String id = sandbox(owner);
        Actor intruder = newActor();
        mvc.perform(get("/v1/bank-feeds/connections/" + id).with(user(intruder.subject()))
                .header("X-Workspace-Id", intruder.workspaceId().toString())).andExpect(status().isNotFound());
        mvc.perform(get("/v1/bank-feeds/" + id + "/proposals").with(user(intruder.subject()))
                .header("X-Workspace-Id", intruder.workspaceId().toString())).andExpect(status().isNotFound());
        refresh(intruder, id).andExpect(status().isNotFound());
        mvc.perform(delete("/v1/bank-feeds/connections/" + id).with(user(intruder.subject()))
                .header("X-Workspace-Id", intruder.workspaceId().toString())).andExpect(status().isNotFound());
        assertThat(mvc.perform(get("/v1/bank-feeds/connections").with(user(intruder.subject()))
                        .header("X-Workspace-Id", intruder.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).doesNotContain(id);
    }

    @Test
    void deletingTheWorkspaceErasesConnectionsTokensAndRecords() throws Exception {
        Actor actor = newActor();
        sandbox(actor);
        mvc.perform(delete("/v1/workspaces/" + actor.workspaceId()).with(user(actor.subject())))
                .andExpect(status().isAccepted());
        jobs.runUntilIdle();
        for (String table : List.of("bank_feed_connection", "bank_feed_account", "bank_feed_token",
                "bank_feed_record")) {
            assertThat(jdbc.sql("select count(*) from " + table + " where workspace_id = ?")
                    .param(actor.workspaceId()).query(Long.class).single()).as(table).isZero();
        }
    }

    @Test
    void unknownProvidersAndMissingPurposeAreRejected() throws Exception {
        Actor actor = newActor();
        connect(actor, "nobody").andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("UNKNOWN_PROVIDER"));
        mvc.perform(post("/v1/bank-feeds/connections").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("provider", "sandbox"))))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("PURPOSE_REQUIRED"));
    }

    private String sandbox(Actor actor) throws Exception {
        String id = connect(actor, "sandbox").andExpect(status().isCreated()).andReturn().getResponse()
                .getContentAsString().transform(json::readTree).path("id").asString();
        jobs.runUntilIdle();
        return id;
    }

    private ResultActions connect(Actor actor, String provider) throws Exception {
        return mvc.perform(post("/v1/bank-feeds/connections").with(user(actor.subject()))
                .header("X-Workspace-Id", actor.workspaceId().toString()).contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("provider", provider, "purpose",
                        "Suggest entries from my bank transactions"))));
    }

    private ResultActions refresh(Actor actor, String id) throws Exception {
        return mvc.perform(post("/v1/bank-feeds/connections/" + id + "/refresh").with(user(actor.subject()))
                .header("X-Workspace-Id", actor.workspaceId().toString()));
    }

    private ResultActions callback(Actor actor, String id, String state, String code) throws Exception {
        return mvc.perform(post("/v1/bank-feeds/connections/" + id + "/consent-callback")
                .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("state", state, "code", code))));
    }

    private ResultActions decide(Actor actor, String id, String recordId, Map<String, String> body)
            throws Exception {
        return mvc.perform(post("/v1/bank-feeds/" + id + "/proposals/" + recordId + "/decision")
                .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString())
                .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)));
    }

    private ResultActions webhook(String provider, String delivery, long timestamp, String body, String signature)
            throws Exception {
        return mvc.perform(post("/v1/bank-feeds/webhooks/" + provider).header("X-Webhook-Id", delivery)
                .header("X-Webhook-Timestamp", Long.toString(timestamp)).header("X-Webhook-Signature", signature)
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private static String sign(String delivery, long timestamp, String body) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(WEBHOOK_SECRET.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        return "v1=" + HexFormat.of().formatHex(mac.doFinal((delivery + "." + timestamp + "." + body)
                .getBytes(StandardCharsets.UTF_8)));
    }

    private long queuedRefreshes(Actor actor) {
        return jdbc.sql("select count(*) from job where workspace_id = ? and type = 'bankfeeds.refresh' "
                + "and status = 'queued'").param(actor.workspaceId()).query(Long.class).single();
    }

    private JsonNode view(Actor actor, String id) throws Exception {
        return json.readTree(mvc.perform(get("/v1/bank-feeds/connections/" + id).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    private JsonNode proposals(Actor actor, String id) throws Exception {
        return json.readTree(mvc.perform(get("/v1/bank-feeds/" + id + "/proposals").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("proposals");
    }

    private JsonNode allProposals(Actor actor, String id) throws Exception {
        return json.readTree(mvc.perform(get("/v1/bank-feeds/" + id + "/proposals").param("status", "all")
                        .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("proposals");
    }

    private static JsonNode find(JsonNode proposals, String providerTransactionId) {
        for (JsonNode proposal : proposals) {
            if (providerTransactionId.equals(proposal.path("providerTransactionId").asString())) {
                return proposal;
            }
        }
        throw new AssertionError("No proposal " + providerTransactionId + " in " + proposals);
    }

    private static List<String> texts(JsonNode proposals, String field) {
        List<String> values = new ArrayList<>();
        proposals.forEach(p -> values.add(p.path(field).asString()));
        return values;
    }

    private static List<String> texts(JsonNode array) {
        List<String> values = new ArrayList<>();
        array.forEach(v -> values.add(v.asString()));
        return values;
    }
}
