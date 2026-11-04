package com.paulsnow.finance.server.inboundmail;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.reset;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;

import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.support.HouseholdSupport;

import tools.jackson.databind.JsonNode;

/**
 * Forwarding addresses, deliveries, collection and retention against the
 * sandbox provider (PRD section 3, P1 email forwarding).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@TestPropertySource(properties = {
        "finance.inbound-mail.sandbox.enabled=true",
        "finance.inbound-mail.token-key=" + InboundMailIntegrationTest.TOKEN_KEY,
        "finance.inbound-mail.domain=receipts.test",
        "finance.inbound-mail.webhook-secrets.sandbox=" + InboundMailIntegrationTest.SECRET })
class InboundMailIntegrationTest extends HouseholdSupport {

    static final String TOKEN_KEY = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
    static final String SECRET = "test-inbound-secret";

    @Autowired
    JdbcClient jdbc;

    @Autowired
    JobRunner jobs;

    @MockitoSpyBean
    ObjectStorage storage;

    @Autowired
    InboundMailMaintenance maintenance;

    @Autowired
    InboundMailPurger purger;

    private String addressPath(Actor actor) {
        return "/v1/workspaces/" + actor.workspaceId() + "/inbound-address";
    }

    private JsonNode createAddress(Actor actor) throws Exception {
        String body = mvc.perform(put(addressPath(actor)).with(user(actor.subject())))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readTree(body);
    }

    @Test
    void statusIsAvailableWithAProviderAndKey() throws Exception {
        Actor actor = newActor();
        mvc.perform(get("/v1/inbound-mail/status").with(user(actor.subject())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.available").value(true));
    }

    @Test
    void putCreatesAnAddressAndGetShowsItAgain() throws Exception {
        Actor actor = newActor();
        String address = createAddress(actor).path("address").asString();
        assertThat(address).matches("^[a-z2-7]{26}@receipts\\.test$");
        mvc.perform(get(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isOk())
                .andExpect(jsonPath("$.address").value(address));
    }

    @Test
    void getBeforeCreatingIsNotFound() throws Exception {
        Actor actor = newActor();
        mvc.perform(get(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isNotFound());
    }

    @Test
    void putReplacesTheAddress() throws Exception {
        Actor actor = newActor();
        String first = createAddress(actor).path("address").asString();
        String second = createAddress(actor).path("address").asString();
        assertThat(second).isNotEqualTo(first);
        assertThat(jdbc.sql("select count(*) from inbound_address where workspace_id = ? and revoked_at is null")
                .param(actor.workspaceId()).query(Long.class).single()).isEqualTo(1L);
    }

    @Test
    void deleteRevokes() throws Exception {
        Actor actor = newActor();
        createAddress(actor);
        mvc.perform(delete(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isNoContent());
        mvc.perform(get(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isNotFound());
    }

    @Test
    void eachMemberHasTheirOwn() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        assertThat(createAddress(owner).path("address").asString())
                .isNotEqualTo(createAddress(member).path("address").asString());
    }

    @Test
    void viewerCannotCreate() throws Exception {
        Actor owner = newActor();
        Actor viewer = join(owner, "viewer");
        mvc.perform(put(addressPath(viewer)).with(user(viewer.subject()))).andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error").value("READ_ONLY"));
    }

    @Test
    void outsidersCannotSeeAWorkspacesAddress() throws Exception {
        Actor owner = newActor();
        createAddress(owner);
        Actor outsider = newActor();
        mvc.perform(get(addressPath(owner)).with(user(outsider.subject()))).andExpect(status().isNotFound());
    }

    @Test
    void tokenIsNotStoredInTheClear() throws Exception {
        Actor actor = newActor();
        String token = createAddress(actor).path("address").asString().split("@")[0];
        Map<String, Object> row = jdbc.sql("select * from inbound_address where workspace_id = ?")
                .param(actor.workspaceId()).query().singleRow();
        assertThat(row.values().toString()).doesNotContain(token);
    }

    // Deliveries ------------------------------------------------------------

    private static byte[] pdf(String marker) {
        return ("%PDF-1.7\n" + marker + "\n%%EOF\n").getBytes(StandardCharsets.ISO_8859_1);
    }

    /** A structurally valid PNG of about {@code size} bytes. */
    private static byte[] png(int size) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(new byte[] { (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
        out.write(ByteBuffer.allocate(4).putInt(13).array());
        out.write("IHDR".getBytes(StandardCharsets.US_ASCII));
        out.write(ByteBuffer.allocate(8).putInt(10).putInt(10).array());
        out.write(new byte[] { 8, 6, 0, 0, 0, 0, 0, 0, 0 });
        out.write(new byte[Math.max(0, size - 41)]);
        out.write("IEND".getBytes(StandardCharsets.US_ASCII));
        out.write(new byte[4]);
        return out.toByteArray();
    }

    private static Map<String, Object> attachment(String fileName, byte[] bytes, boolean inline) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("fileName", fileName);
        result.put("contentBase64", Base64.getEncoder().encodeToString(bytes));
        result.put("inline", inline);
        return result;
    }

    private byte[] message(String id, String to, List<Map<String, Object>> attachments) throws Exception {
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("messageId", id);
        message.put("to", to);
        message.put("from", "shop@example.com");
        message.put("subject", "Your receipt");
        message.put("attachments", attachments);
        return json.writeValueAsBytes(message);
    }

    private static String sign(String secret, String id, String timestamp, byte[] body) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        mac.update((id + "." + timestamp + ".").getBytes(StandardCharsets.UTF_8));
        return "v1=" + HexFormat.of().formatHex(mac.doFinal(body));
    }

    private org.springframework.test.web.servlet.ResultActions send(String provider, byte[] body, String timestamp,
            String signature) throws Exception {
        return mvc.perform(post("/v1/inbound-mail/webhooks/" + provider).header("X-Webhook-Id", "d-1")
                .header("X-Webhook-Timestamp", timestamp).header("X-Webhook-Signature", signature)
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private String now() {
        return Long.toString(clock.instant().getEpochSecond());
    }

    /** Posts a correctly signed delivery and runs the job it queues. */
    private void deliver(byte[] body) throws Exception {
        String timestamp = now();
        send("sandbox", body, timestamp, sign(SECRET, "d-1", timestamp, body)).andExpect(status().isAccepted())
                .andExpect(jsonPath("$.status").value("accepted"));
        jobs.runUntilIdle();
    }

    private String address(Actor actor) throws Exception {
        return createAddress(actor).path("address").asString();
    }

    private static String id() {
        return UUID.randomUUID().toString();
    }

    private String outcome(String messageId) {
        return jdbc.sql("select outcome from inbound_message where provider_message_id = ?").param(messageId)
                .query(String.class).single();
    }

    private List<Map<String, Object>> documents(String messageId) {
        return jdbc.sql("select d.* from inbound_document d join inbound_message m on m.id = d.message_id "
                + "where m.provider_message_id = ? order by d.attachment_index").param(messageId).query().listOfRows();
    }

    private long auditCount(String kind) {
        return jdbc.sql("select count(*) from audit_event where kind = ?").param(kind).query(Long.class).single();
    }

    @Test
    void invalidSignatureIsRefused() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] body = message(messageId, address(actor), List.of());
        send("sandbox", body, now(), sign("wrong-secret", "d-1", now(), body)).andExpect(status().isUnauthorized());
        jobs.runUntilIdle();
        assertThat(jdbc.sql("select count(*) from inbound_message where provider_message_id = ?").param(messageId)
                .query(Long.class).single()).isZero();
    }

    @Test
    void staleTimestampIsRefused() throws Exception {
        Actor actor = newActor();
        byte[] body = message(id(), address(actor), List.of());
        String old = Long.toString(clock.instant().getEpochSecond() - 3600);
        send("sandbox", body, old, sign(SECRET, "d-1", old, body)).andExpect(status().isUnauthorized());
    }

    @Test
    void unknownProviderIsRefused() throws Exception {
        byte[] body = message(id(), "nobody@receipts.test", List.of());
        send("no-such-provider", body, now(), sign(SECRET, "d-1", now(), body)).andExpect(status().isUnauthorized());
    }

    @Test
    void oversizedDeliveryIsRefused() throws Exception {
        byte[] body = new byte[67_108_865];
        send("sandbox", body, now(), sign(SECRET, "d-1", now(), body)).andExpect(status().isPayloadTooLarge());
    }

    @Test
    void pdfAttachmentBecomesAWaitingDocument() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("receipt.pdf", pdf("one"), false))));

        assertThat(outcome(messageId)).isEqualTo("documents");
        List<Map<String, Object>> documents = documents(messageId);
        assertThat(documents).hasSize(1);
        assertThat(documents.getFirst().get("state")).isEqualTo("waiting");
        assertThat(documents.getFirst().get("content_type")).isEqualTo("application/pdf");
        String key = (String) documents.getFirst().get("object_key");
        assertThat(key).startsWith("inbound-mail/" + actor.workspaceId() + "/");
        assertThat(storage.head(key)).isPresent();
        assertThat(storage.deletePrefix("inbound-mail/raw/")).isZero();
    }

    @Test
    void addressMatchingIgnoresCase() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor).toUpperCase(), List.of()));
        assertThat(outcome(messageId)).isEqualTo("no_attachment");
    }

    @Test
    void repeatedDeliveryIsHandledOnce() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] body = message(messageId, address(actor), List.of(attachment("receipt.pdf", pdf("one"), false)));
        deliver(body);
        deliver(body);
        assertThat(jdbc.sql("select count(*) from inbound_message where provider_message_id = ?").param(messageId)
                .query(Long.class).single()).isEqualTo(1L);
        assertThat(documents(messageId)).hasSize(1);
    }

    @Test
    void unknownAndRevokedAddressesLookAccepted() throws Exception {
        Actor actor = newActor();
        String revoked = address(actor);
        mvc.perform(delete(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isNoContent());
        long before = auditCount("inbound_mail.dropped");
        String unknown = id();
        String stopped = id();
        deliver(message(unknown, "abcdefghijklmnopqrstuvwxyz@receipts.test", List.of()));
        deliver(message(stopped, revoked, List.of(attachment("receipt.pdf", pdf("one"), false))));
        assertThat(jdbc.sql("select count(*) from inbound_message where provider_message_id in (?, ?)")
                .params(unknown, stopped).query(Long.class).single()).isZero();
        assertThat(auditCount("inbound_mail.dropped")).isEqualTo(before + 2);
    }

    @Test
    void anotherDomainIsDropped() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        String token = address(actor).split("@")[0];
        deliver(message(messageId, token + "@elsewhere.test", List.of()));
        assertThat(jdbc.sql("select count(*) from inbound_message where provider_message_id = ?").param(messageId)
                .query(Long.class).single()).isZero();
    }

    @Test
    void disguisedFileIsRejected() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] executable = new byte[] { 0x4D, 0x5A, (byte) 0x90, 0, 3, 0, 0, 0 };
        deliver(message(messageId, address(actor), List.of(attachment("receipt.pdf", executable, false))));
        assertThat(outcome(messageId)).isEqualTo("rejected");
        Map<String, Object> document = documents(messageId).getFirst();
        assertThat(document.get("state")).isEqualTo("rejected");
        assertThat(document.get("rejection_code")).isEqualTo("UNSUPPORTED_TYPE");
        assertThat(document.get("object_key")).isNull();
    }

    @Test
    void activePdfIsRejected() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("a.pdf", pdf("/JavaScript (x)"), false))));
        assertThat(documents(messageId).getFirst().get("rejection_code")).isEqualTo("ACTIVE_CONTENT");
    }

    @Test
    void noAttachmentIsReported() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of()));
        assertThat(outcome(messageId)).isEqualTo("no_attachment");
        assertThat(jdbc.sql("select column_name from information_schema.columns where table_name = 'inbound_message'")
                .query(String.class).list()).doesNotContain("body");
    }

    @Test
    void mixedMessage() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        List<Map<String, Object>> attachments = new ArrayList<>();
        attachments.add(attachment("logo.png", png(10_240), true));
        attachments.add(attachment("photo.png", png(30_720), true));
        attachments.add(attachment("evil.pdf", new byte[] { 0x4D, 0x5A, 0, 0 }, false));
        for (int i = 0; i < 9; i++) {
            attachments.add(attachment("r" + i + ".pdf", pdf("doc" + i), false));
        }
        deliver(message(messageId, address(actor), attachments));

        assertThat(outcome(messageId)).isEqualTo("documents");
        List<Map<String, Object>> documents = documents(messageId);
        assertThat(documents).noneMatch(d -> "logo.png".equals(d.get("file_name")));
        assertThat(documents.stream().filter(d -> "waiting".equals(d.get("state")))).hasSize(9);
        assertThat(documents.stream().filter(d -> "UNSUPPORTED_TYPE".equals(d.get("rejection_code")))).hasSize(1);
        assertThat(documents.stream().filter(d -> "TOO_MANY".equals(d.get("rejection_code")))).hasSize(1);
    }

    @Test
    void tooLargeAttachmentIsRejected() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] large = Arrays.copyOf(pdf("big"), 20_971_521);
        deliver(message(messageId, address(actor), List.of(attachment("big.pdf", large, false))));
        assertThat(documents(messageId).getFirst().get("rejection_code")).isEqualTo("TOO_LARGE");
    }

    @Test
    void rateLimitApplies() throws Exception {
        Actor actor = newActor();
        String to = address(actor);
        for (int i = 0; i < 50; i++) {
            deliver(message(id(), to, List.of()));
        }
        String messageId = id();
        deliver(message(messageId, to, List.of(attachment("receipt.pdf", pdf("one"), false))));
        assertThat(outcome(messageId)).isEqualTo("rate_limited");
        assertThat(documents(messageId)).isEmpty();
    }

    @Test
    @ExtendWith(OutputCaptureExtension.class)
    void hostileTextIsBounded(CapturedOutput output) throws Exception {
        Actor actor = newActor();
        String messageId = id();
        String subject = "S3cretSubject" + "x".repeat(1000);
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("messageId", messageId);
        message.put("to", address(actor));
        message.put("from", "hidden-sender@example.com");
        message.put("subject", subject);
        message.put("attachments", List.of(attachment("../../evil\u0000\u202E.pdf", pdf("one"), false)));
        deliver(json.writeValueAsBytes(message));

        assertThat(documents(messageId).getFirst().get("file_name")).isEqualTo("evil.pdf");
        String stored = jdbc.sql("select subject from inbound_message where provider_message_id = ?").param(messageId)
                .query(String.class).single();
        assertThat(stored).hasSize(200);
        assertThat(output.getAll()).doesNotContain("S3cretSubject").doesNotContain("hidden-sender@example.com")
                .doesNotContain("evil");
    }

    @Test
    void malformedDeliveryDoesNotPoisonTheQueue() throws Exception {
        byte[] body = "not json".getBytes(StandardCharsets.UTF_8);
        deliver(body);
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of()));
        assertThat(outcome(messageId)).isEqualTo("no_attachment");
    }

    // Collection ------------------------------------------------------------

    private String documentsPath(Actor actor) {
        return "/v1/workspaces/" + actor.workspaceId() + "/inbound-documents";
    }

    private JsonNode inbox(Actor actor) throws Exception {
        return json.readTree(mvc.perform(get(documentsPath(actor)).with(user(actor.subject())))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    /** Delivers one PDF to the actor's address and returns the document's id. */
    private String waitingDocument(Actor actor) throws Exception {
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("receipt.pdf", pdf(messageId), false))));
        return documents(messageId).getFirst().get("id").toString();
    }

    private org.springframework.test.web.servlet.ResultActions rejectAs(Actor caller, Actor owner, String documentId)
            throws Exception {
        return mvc.perform(post(documentsPath(owner) + "/" + documentId + "/reject").with(user(caller.subject()))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("code", "REJECTED_ON_DEVICE", "detail", "x".repeat(500)))));
    }

    @Test
    void listDescribesWaitingDocuments() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        JsonNode document = inbox(actor).path("documents").get(0);
        assertThat(document.path("id").asString()).isEqualTo(documentId);
        assertThat(document.path("fileName").asString()).isEqualTo("receipt.pdf");
        assertThat(document.path("contentType").asString()).isEqualTo("application/pdf");
        assertThat(document.path("sizeBytes").asLong()).isPositive();
        assertThat(document.path("sha256").asString()).hasSize(64);
        assertThat(document.path("receivedAt").asString()).isNotBlank();
    }

    @Test
    void listShowsOnlyTheCallersDocuments() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        waitingDocument(owner);
        assertThat(inbox(owner).path("documents")).hasSize(1);
        assertThat(inbox(member).path("documents")).isEmpty();
    }

    @Test
    void downloadGivesAShortLivedLinkToTheBytes() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        mvc.perform(get(documentsPath(actor) + "/" + documentId + "/download").with(user(actor.subject())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.url").isNotEmpty())
                .andExpect(jsonPath("$.expiresAt").isNotEmpty());
    }

    @Test
    void anotherMemberOrWorkspaceGets404() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        Actor outsider = newActor();
        String documentId = waitingDocument(owner);
        String missing = mvc.perform(get(documentsPath(owner) + "/" + UUID.randomUUID() + "/download")
                .with(user(owner.subject()))).andExpect(status().isNotFound()).andReturn().getResponse()
                .getContentAsString();

        String other = mvc.perform(get(documentsPath(member) + "/" + documentId + "/download")
                .with(user(member.subject()))).andExpect(status().isNotFound()).andReturn().getResponse()
                .getContentAsString();
        // Only the per-request correlation identifier differs.
        assertThat(json.readTree(other).path("error")).isEqualTo(json.readTree(missing).path("error"));
        assertThat(json.readTree(other).path("message")).isEqualTo(json.readTree(missing).path("message"));
        mvc.perform(post(documentsPath(member) + "/" + documentId + "/acknowledge").with(user(member.subject())))
                .andExpect(status().isNotFound());
        rejectAs(member, member, documentId).andExpect(status().isNotFound());
        mvc.perform(get(documentsPath(outsider) + "/" + documentId + "/download").with(user(outsider.subject())))
                .andExpect(status().isNotFound());
        // An outsider using the owner's workspace in the path is refused too.
        mvc.perform(get(documentsPath(owner) + "/" + documentId + "/download").with(user(outsider.subject())))
                .andExpect(status().isNotFound());
        assertThat(inbox(owner).path("documents")).hasSize(1);
    }

    @Test
    void acknowledgeDeletesTheObjectAndIsIdempotent() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        String key = "inbound-mail/" + actor.workspaceId() + "/" + documentId;
        assertThat(storage.head(key)).isPresent();
        String path = documentsPath(actor) + "/" + documentId + "/acknowledge";
        mvc.perform(post(path).with(user(actor.subject()))).andExpect(status().isNoContent());
        assertThat(storage.head(key)).isEmpty();
        assertThat(inbox(actor).path("documents")).isEmpty();
        mvc.perform(post(path).with(user(actor.subject()))).andExpect(status().isNoContent());
    }

    @Test
    void downloadAfterAcknowledgeIs404() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        mvc.perform(post(documentsPath(actor) + "/" + documentId + "/acknowledge").with(user(actor.subject())))
                .andExpect(status().isNoContent());
        mvc.perform(get(documentsPath(actor) + "/" + documentId + "/download").with(user(actor.subject())))
                .andExpect(status().isNotFound());
    }

    @Test
    void rejectRecordsTheReasonAndDeletes() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        String key = "inbound-mail/" + actor.workspaceId() + "/" + documentId;
        rejectAs(actor, actor, documentId).andExpect(status().isNoContent());
        assertThat(storage.head(key)).isEmpty();
        JsonNode inbox = inbox(actor);
        assertThat(inbox.path("documents")).isEmpty();
        JsonNode rejection = inbox.path("notices").get(0).path("rejections").get(0);
        assertThat(rejection.path("fileName").asString()).isEqualTo("receipt.pdf");
        assertThat(rejection.path("code").asString()).isEqualTo("REJECTED_ON_DEVICE");
        assertThat(rejection.path("detail").asString()).hasSize(200);
        rejectAs(actor, actor, documentId).andExpect(status().isNoContent());
    }

    @Test
    void noticesExplainWhatDidNotBecomeAReceipt() throws Exception {
        Actor actor = newActor();
        String empty = id();
        deliver(message(empty, address(actor), List.of()));
        JsonNode notice = inbox(actor).path("notices").get(0);
        assertThat(notice.path("messageId").asString()).isNotBlank();
        assertThat(notice.path("sender").asString()).isEqualTo("shop@example.com");
        assertThat(notice.path("outcome").asString()).isEqualTo("no_attachment");
        assertThat(notice.path("receivedAt").asString()).isNotBlank();
    }

    @Test
    void aMessageThatArrivedCleanlyIsNotANotice() throws Exception {
        Actor actor = newActor();
        waitingDocument(actor);
        assertThat(inbox(actor).path("notices")).isEmpty();
    }

    @Test
    void viewerCannotCollect() throws Exception {
        Actor owner = newActor();
        Actor viewer = join(owner, "viewer");
        String any = UUID.randomUUID().toString();
        mvc.perform(get(documentsPath(viewer)).with(user(viewer.subject()))).andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error").value("READ_ONLY"));
        mvc.perform(get(documentsPath(viewer) + "/" + any + "/download").with(user(viewer.subject())))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("READ_ONLY"));
        mvc.perform(post(documentsPath(viewer) + "/" + any + "/acknowledge").with(user(viewer.subject())))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("READ_ONLY"));
        rejectAs(viewer, viewer, any).andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("READ_ONLY"));
    }

    @Test
    void auditHasNoEmailContent() throws Exception {
        Actor actor = newActor();
        String first = waitingDocument(actor);
        String second = waitingDocument(actor);
        mvc.perform(post(documentsPath(actor) + "/" + first + "/acknowledge").with(user(actor.subject())))
                .andExpect(status().isNoContent());
        rejectAs(actor, actor, second).andExpect(status().isNoContent());
        List<Map<String, Object>> rows = jdbc.sql("select * from audit_event where workspace_id = ? "
                + "and kind like 'inbound_mail.%'").param(actor.workspaceId()).query().listOfRows();
        assertThat(rows.stream().map(row -> row.get("kind"))).contains("inbound_mail.collected",
                "inbound_mail.rejected_on_device");
        assertThat(rows.toString()).doesNotContain("shop@example.com").doesNotContain("Your receipt")
                .doesNotContain("receipt.pdf");
    }

    // Retention and membership ----------------------------------------------

    private org.springframework.test.web.servlet.ResultActions changeRole(Actor owner, UUID userId, String role)
            throws Exception {
        return mvc.perform(patch("/v1/workspaces/" + owner.workspaceId() + "/members/" + userId)
                .with(user(owner.subject())).contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("role", role))));
    }

    private UUID userIdOf(Actor actor) {
        return jdbc.sql("select user_id from device where id = ?").param(actor.deviceId()).query(UUID.class).single();
    }

    private String objectKey(Actor actor, String documentId) {
        return "inbound-mail/" + actor.workspaceId() + "/" + documentId;
    }

    private long activeAddresses(Actor actor) {
        return jdbc.sql("select count(*) from inbound_address where user_id = ? and revoked_at is null")
                .param(userIdOf(actor)).query(Long.class).single();
    }

    private long messagesIn(Actor actor) {
        return jdbc.sql("select count(*) from inbound_message where workspace_id = ?").param(actor.workspaceId())
                .query(Long.class).single();
    }

    @Test
    void expiredMessagesAreRemoved() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        clock.advance(java.time.Duration.ofDays(29));
        maintenance.sweep();
        assertThat(storage.head(objectKey(actor, documentId))).isPresent();
        assertThat(messagesIn(actor)).isEqualTo(1L);

        clock.advance(java.time.Duration.ofDays(2));
        maintenance.sweep();
        assertThat(storage.head(objectKey(actor, documentId))).isEmpty();
        assertThat(messagesIn(actor)).isZero();
    }

    @Test
    void stuckProcessingBecomesFailed() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of()));
        jdbc.sql("update inbound_message set outcome = 'processing' where provider_message_id = ?").param(messageId)
                .update();
        maintenance.sweep();
        assertThat(outcome(messageId)).isEqualTo("processing");

        clock.advance(java.time.Duration.ofMinutes(61));
        maintenance.sweep();
        assertThat(outcome(messageId)).isEqualTo("failed");
        assertThat(inbox(actor).path("notices").get(0).path("outcome").asString()).isEqualTo("failed");
    }

    @Test
    void removingAMemberRevokesAndDeletes() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        String documentId = waitingDocument(member);
        mvc.perform(delete("/v1/workspaces/" + owner.workspaceId() + "/members/" + userIdOf(member))
                .with(user(owner.subject()))).andExpect(status().isNoContent());
        assertThat(activeAddresses(member)).isZero();
        assertThat(storage.head(objectKey(member, documentId))).isEmpty();
        assertThat(messagesIn(member)).isZero();
    }

    @Test
    void demotingToViewerRevokesAndDeletes() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        String documentId = waitingDocument(member);
        changeRole(owner, userIdOf(member), "viewer").andExpect(status().is2xxSuccessful());
        assertThat(activeAddresses(member)).isZero();
        assertThat(storage.head(objectKey(member, documentId))).isEmpty();
    }

    @Test
    void otherRoleChangesKeepTheAddress() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        String documentId = waitingDocument(member);
        changeRole(owner, userIdOf(member), "owner").andExpect(status().is2xxSuccessful());
        changeRole(owner, userIdOf(member), "member").andExpect(status().is2xxSuccessful());
        assertThat(activeAddresses(member)).isEqualTo(1L);
        assertThat(storage.head(objectKey(member, documentId))).isPresent();
    }

    @Test
    void removingOneMemberLeavesAnothersDocuments() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        String ownersDocument = waitingDocument(owner);
        waitingDocument(member);
        mvc.perform(delete("/v1/workspaces/" + owner.workspaceId() + "/members/" + userIdOf(member))
                .with(user(owner.subject()))).andExpect(status().isNoContent());
        assertThat(storage.head(objectKey(owner, ownersDocument))).isPresent();
        assertThat(activeAddresses(owner)).isEqualTo(1L);
    }

    @Test
    void deletingAWorkspacePurgesEverything() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        assertThat(purger.step()).isEqualTo("inboundmail");
        purger.purge(actor.workspaceId());
        assertThat(storage.head(objectKey(actor, documentId))).isEmpty();
        assertThat(messagesIn(actor)).isZero();
        assertThat(jdbc.sql("select count(*) from inbound_address where workspace_id = ?").param(actor.workspaceId())
                .query(Long.class).single()).isZero();
    }

    @Test
    void revokingKeepsWaitingDocuments() throws Exception {
        Actor actor = newActor();
        String documentId = waitingDocument(actor);
        mvc.perform(delete(addressPath(actor)).with(user(actor.subject()))).andExpect(status().isNoContent());
        assertThat(inbox(actor).path("documents")).hasSize(1);
        mvc.perform(get(documentsPath(actor) + "/" + documentId + "/download").with(user(actor.subject())))
                .andExpect(status().isOk());
    }

    // Review findings -------------------------------------------------------

    @Test
    void outcomeCountsWhatADeviceAlreadyCollected() {
        assertThat(InboundProcessJobHandler.outcomeOf(List.of("collected"))).isEqualTo("documents");
        assertThat(InboundProcessJobHandler.outcomeOf(List.of("collected", "rejected"))).isEqualTo("documents");
        assertThat(InboundProcessJobHandler.outcomeOf(List.of("waiting", "rejected"))).isEqualTo("documents");
        assertThat(InboundProcessJobHandler.outcomeOf(List.of("rejected"))).isEqualTo("rejected");
        assertThat(InboundProcessJobHandler.outcomeOf(List.of())).isEqualTo("no_attachment");
    }

    @Test
    void aMessageStillBeingHandledIsNotANotice() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("a.pdf", new byte[] { 0x4D, 0x5A }, false))));
        jdbc.sql("update inbound_message set outcome = 'processing' where provider_message_id = ?").param(messageId)
                .update();
        assertThat(inbox(actor).path("notices")).isEmpty();
    }

    @Test
    void anExecutableCarryingAPdfHeaderIsRejected() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] polyglot = ("MZ" + "x".repeat(200) + "%PDF-1.7\n%%EOF\n").getBytes(StandardCharsets.ISO_8859_1);
        deliver(message(messageId, address(actor), List.of(attachment("invoice.pdf", polyglot, false))));
        assertThat(outcome(messageId)).isEqualTo("rejected");
        assertThat(documents(messageId).getFirst().get("rejection_code")).isEqualTo("UNSUPPORTED_TYPE");
    }

    @Test
    void recentListsTheLatestEmailsNewestFirst() throws Exception {
        Actor actor = newActor();
        String to = address(actor);
        String first = id();
        deliver(message(first, to, List.of(attachment("receipt.pdf", pdf("one"), false))));
        clock.advance(java.time.Duration.ofMinutes(1));
        deliver(message(id(), to, List.of()));
        JsonNode recent = inbox(actor).path("recent");
        assertThat(recent).hasSize(2);
        assertThat(recent.get(0).path("outcome").asString()).isEqualTo("no_attachment");
        assertThat(recent.get(1).path("outcome").asString()).isEqualTo("documents");
        assertThat(recent.get(1).path("sender").asString()).isEqualTo("shop@example.com");
        assertThat(recent.get(1).path("receivedAt").asString()).isNotBlank();
    }

    @Test
    void recentIsLimited() throws Exception {
        Actor actor = newActor();
        String to = address(actor);
        for (int i = 0; i < 22; i++) {
            deliver(message(id(), to, List.of()));
        }
        assertThat(inbox(actor).path("recent")).hasSize(20);
    }

    @Test
    void recentShowsOnlyTheCallersEmails() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        waitingDocument(owner);
        assertThat(inbox(member).path("recent")).isEmpty();
    }

    @Test
    void aStorageOutageDoesNotStopAMemberBeingRemoved() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        waitingDocument(member);
        doThrow(new IllegalStateException("storage unavailable")).when(storage).delete(anyString());
        try {
            mvc.perform(delete("/v1/workspaces/" + owner.workspaceId() + "/members/" + userIdOf(member))
                    .with(user(owner.subject()))).andExpect(status().isNoContent());
        } finally {
            reset(storage);
        }
        assertThat(activeAddresses(member)).isZero();
        assertThat(jdbc.sql("select count(*) from membership where workspace_id = ? and user_id = ?")
                .params(owner.workspaceId(), userIdOf(member)).query(Long.class).single()).isZero();
        assertThat(jdbc.sql("select count(*) from inbound_message m where m.workspace_id = ? and m.user_id = ?")
                .params(owner.workspaceId(), userIdOf(member)).query(Long.class).single()).isZero();
    }

    @Test
    void aMessageWhoseDocumentsWereAllRefusedOnTheDeviceIsRejected() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("a.pdf", pdf("one"), false),
                attachment("b.pdf", pdf("two"), false))));
        List<Map<String, Object>> documents = documents(messageId);
        rejectAs(actor, actor, documents.get(0).get("id").toString()).andExpect(status().isNoContent());
        assertThat(outcome(messageId)).isEqualTo("documents");
        rejectAs(actor, actor, documents.get(1).get("id").toString()).andExpect(status().isNoContent());
        assertThat(outcome(messageId)).isEqualTo("rejected");
    }

    @Test
    void aRejectionAfterACollectionLeavesTheMessageReceived() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        deliver(message(messageId, address(actor), List.of(attachment("a.pdf", pdf("one"), false),
                attachment("b.pdf", pdf("two"), false))));
        List<Map<String, Object>> documents = documents(messageId);
        mvc.perform(post(documentsPath(actor) + "/" + documents.get(0).get("id") + "/acknowledge")
                .with(user(actor.subject()))).andExpect(status().isNoContent());
        rejectAs(actor, actor, documents.get(1).get("id").toString()).andExpect(status().isNoContent());
        assertThat(outcome(messageId)).isEqualTo("documents");
    }

    @Test
    void aMemberRemovedWhileADeliveryIsHandledLeavesNoObjectBehind() throws Exception {
        Actor actor = newActor();
        String messageId = id();
        byte[] body = message(messageId, address(actor), List.of(attachment("receipt.pdf", pdf("one"), false)));
        String prefix = "inbound-mail/" + actor.workspaceId() + "/";
        List<String> stored = new ArrayList<>();
        doAnswer(invocation -> {
            Object result = invocation.callRealMethod();
            String key = invocation.getArgument(0);
            if (key.startsWith(prefix)) {
                stored.add(key);
                jdbc.sql("delete from inbound_message where provider_message_id = ?").param(messageId).update();
            }
            return result;
        }).when(storage).put(anyString(), any(), anyString(), any());
        try {
            deliver(body);
        } finally {
            reset(storage);
        }
        assertThat(stored).hasSize(1);
        assertThat(storage.head(stored.getFirst())).isEmpty();
    }
}
