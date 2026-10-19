package com.paulsnow.finance.server.receipts;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Map;

import javax.imageio.ImageIO;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.ResultActions;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.support.IntegrationTestSupport;
import com.paulsnow.finance.server.support.TestcontainersConfiguration;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import tools.jackson.databind.JsonNode;

/**
 * Receipt documents (SYNC 05, SEC 04, A17): upload intents, direct upload
 * to object storage, verified completion, quarantine and scanning, and
 * workspace-scoped download.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ReceiptsIntegrationTest extends IntegrationTestSupport {

    private final HttpClient http = HttpClient.newHttpClient();

    @Autowired
    JobRunner jobs;

    @Autowired
    JdbcClient jdbc;

    @Autowired
    MeterRegistry meters;

    @Test
    void uploadsCompletesQuarantinesScansAndDownloads() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);
        String assetId = Ids.newId();
        byte[] bytes = png();

        JsonNode intent = intent(actor, receiptId, assetId, "image/png", bytes).andExpect(status().isOk())
                .andExpect(jsonPath("$.uploadUrl").isNotEmpty())
                .andExpect(jsonPath("$.expiresAt").isNotEmpty())
                // Staging uploads are tagged so the bucket lifecycle expires them (SEC 06).
                .andExpect(jsonPath("$.headers['x-amz-tagging']").value("finance-retention=staging"))
                .andReturn().getResponse().getContentAsString().transform(this::read);
        assertThat(put(intent, bytes)).isEqualTo(200);

        complete(actor, receiptId, assetId).andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("quarantined"));
        download(actor, receiptId, assetId).andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("ASSET_NOT_AVAILABLE"));

        long scansBefore = extractions("available");
        jobs.runUntilIdle();
        assertThat(extractions("available")).isEqualTo(scansBefore + 1);
        assertThat(meters.get("finance.extraction.latency").tag("outcome", "available").timer().takeSnapshot()
                .histogramCounts()).as("histogram buckets for quantiles").isNotEmpty();

        JsonNode link = read(download(actor, receiptId, assetId).andExpect(status().isOk())
                .andExpect(jsonPath("$.expiresAt").isNotEmpty())
                .andReturn().getResponse().getContentAsString());
        HttpResponse<byte[]> fetched = http.send(HttpRequest.newBuilder(URI.create(link.path("downloadUrl")
                .asString())).GET().build(), HttpResponse.BodyHandlers.ofByteArray());
        assertThat(fetched.statusCode()).isEqualTo(200);
        assertThat(fetched.body()).isEqualTo(bytes);

        // Completing again is a no-op and never creates a second receipt.
        complete(actor, receiptId, assetId).andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("available"));
        assertThat(jdbc.sql("select count(*) from receipt_document where receipt_id = ?::uuid").param(receiptId)
                .query(Long.class).single()).isEqualTo(1);
        assertThat(jdbc.sql("select count(*) from receipt_asset where asset_id = ?::uuid").param(assetId)
                .query(Long.class).single()).isEqualTo(1);
    }

    @Test
    void reRequestingAnIntentTargetsTheSameObject() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);
        String assetId = Ids.newId();
        byte[] bytes = jpeg();
        JsonNode first = read(intent(actor, receiptId, assetId, "image/jpeg", bytes).andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString());
        JsonNode second = read(intent(actor, receiptId, assetId, "image/jpeg", bytes).andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString());
        assertThat(path(second)).isEqualTo(path(first));
        assertThat(put(second, bytes)).isEqualTo(200);
        complete(actor, receiptId, assetId).andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("quarantined"));
    }

    @Test
    void rejectsCompletionWhenChecksumSizeOrContentDoNotMatch() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);

        String tampered = Ids.newId();
        byte[] declared = png();
        JsonNode intent = read(intent(actor, receiptId, tampered, "image/png", declared)
                .andReturn().getResponse().getContentAsString());
        byte[] other = declared.clone();
        other[other.length - 20] ^= 0x01;
        put(intent, other);
        complete(actor, receiptId, tampered).andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.error").value("CHECKSUM_MISMATCH"));

        // After a corrected upload the same asset completes.
        put(intent, declared);
        complete(actor, receiptId, tampered).andExpect(status().isOk());

        String disguised = Ids.newId();
        byte[] pdf = pdf("plain receipt");
        JsonNode pdfIntent = read(intent(actor, receiptId, disguised, "image/jpeg", pdf)
                .andReturn().getResponse().getContentAsString());
        put(pdfIntent, pdf);
        complete(actor, receiptId, disguised).andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.error").value("CONTENT_TYPE_MISMATCH"));

        String missing = Ids.newId();
        intent(actor, receiptId, missing, "image/png", declared).andExpect(status().isOk());
        complete(actor, receiptId, missing).andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("OBJECT_MISSING"));
    }

    @Test
    void aReceiptsSourceDocumentsHoldAtMostTenPages() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);
        assertThat(upload(actor, receiptId, "source", pages(7))).isEqualTo(200);
        assertThat(upload(actor, receiptId, "source", jpeg())).isEqualTo(200);
        // A derivative is another rendering of a source, not more pages.
        assertThat(upload(actor, receiptId, "derivative", pages(5))).isEqualTo(200);

        String tooMany = Ids.newId();
        byte[] three = pages(3);
        put(read(intent(actor, receiptId, tooMany, "application/pdf", three).andReturn().getResponse()
                .getContentAsString()), three);
        complete(actor, receiptId, tooMany).andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.error").value("TOO_MANY_PAGES"));
        assertThat(upload(actor, receiptId, "source", pages(2))).isEqualTo(200);

        String other = createReceipt(actor);
        String eleven = Ids.newId();
        byte[] elevenPages = pages(11);
        put(read(intent(actor, other, eleven, "application/pdf", elevenPages).andReturn().getResponse()
                .getContentAsString()), elevenPages);
        complete(actor, other, eleven).andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.error").value("TOO_MANY_PAGES"));
    }

    @Test
    void scannerRejectsActiveContentAndItIsNeverDownloadable() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);
        String assetId = Ids.newId();
        byte[] bytes = pdf("/OpenAction << /S /JavaScript /JS (app.alert(1)) >>");
        put(read(intent(actor, receiptId, assetId, "application/pdf", bytes).andReturn().getResponse()
                .getContentAsString()), bytes);
        complete(actor, receiptId, assetId).andExpect(status().isOk());
        jobs.runUntilIdle();
        assertThat(jdbc.sql("select status from receipt_asset where asset_id = ?::uuid").param(assetId)
                .query(String.class).single()).isEqualTo("rejected");
        download(actor, receiptId, assetId).andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("ASSET_NOT_AVAILABLE"));
    }

    @Test
    void validatesIntentsAndRequiresAReceiptOwnedByTheWorkspace() throws Exception {
        Actor actor = newActor();
        String receiptId = createReceipt(actor);
        byte[] bytes = png();
        intent(actor, Ids.newId(), Ids.newId(), "image/png", bytes).andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("RECEIPT_NOT_FOUND"));
        intent(actor, receiptId, Ids.newId(), "application/x-msdownload", bytes)
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("UNSUPPORTED_CONTENT_TYPE"));
        mvc.perform(post("/v1/receipts/upload-intents").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("receiptId", receiptId, "assetId", Ids.newId(),
                                "kind", "source", "contentType", "image/png", "sizeBytes", 1_000_000_000L,
                                "sha256", sha256(bytes)))))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("TOO_LARGE"));
        // REC 05: 20 MiB per file, as the client's ContentLimits.
        intent(actor, receiptId, Ids.newId(), "source", "image/png", 20L * 1024 * 1024, sha256(bytes))
                .andExpect(status().isOk());
        intent(actor, receiptId, Ids.newId(), "source", "image/png", 20L * 1024 * 1024 + 1, sha256(bytes))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("TOO_LARGE"));
    }

    @Test
    void a17AnotherWorkspaceCannotReachAReceiptByIdOrObjectKey() throws Exception {
        Actor owner = newActor();
        String receiptId = createReceipt(owner);
        String assetId = Ids.newId();
        byte[] bytes = png();
        put(read(intent(owner, receiptId, assetId, "image/png", bytes).andReturn().getResponse()
                .getContentAsString()), bytes);
        complete(owner, receiptId, assetId).andExpect(status().isOk());
        jobs.runUntilIdle();

        Actor intruder = newActor();
        String body = download(intruder, receiptId, assetId).andExpect(status().isNotFound())
                .andReturn().getResponse().getContentAsString();
        assertThat(body).doesNotContain(sha256(bytes)).doesNotContain("image/png")
                .doesNotContain(owner.workspaceId().toString());
        complete(intruder, receiptId, assetId).andExpect(status().isNotFound());

        // Even with a receipt entity of the same identifier in its own
        // workspace, the intruder cannot attach to or overwrite the object.
        submitOne(intruder, upsert(intruder, "receipt", receiptId, 0, Map.of("merchant", "x")));
        intent(intruder, receiptId, assetId, "image/png", bytes).andExpect(status().isNotFound());
        intent(intruder, receiptId, Ids.newId(), "image/png", bytes).andExpect(status().isNotFound());

        // The bucket is private: the object key alone gives no access.
        String key = jdbc.sql("select object_key from receipt_asset where asset_id = ?::uuid").param(assetId)
                .query(String.class).single();
        HttpResponse<String> anonymous = http.send(HttpRequest.newBuilder(URI.create(
                TestcontainersConfiguration.objectStorageEndpoint() + "/finance-test/" + key)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(anonymous.statusCode()).isEqualTo(403);
    }

    private String createReceipt(Actor actor) throws Exception {
        String receiptId = Ids.newId();
        JsonNode result = submitOne(actor, upsert(actor, "receipt", receiptId, 0, Map.of("status", "captured")));
        assertThat(result.path("status").asString()).isEqualTo("applied");
        return receiptId;
    }

    private ResultActions intent(Actor actor, String receiptId, String assetId, String contentType, byte[] bytes)
            throws Exception {
        return intent(actor, receiptId, assetId, "source", contentType, bytes.length, sha256(bytes));
    }

    private ResultActions intent(Actor actor, String receiptId, String assetId, String kind, String contentType,
            long sizeBytes, String sha256) throws Exception {
        return mvc.perform(post("/v1/receipts/upload-intents").with(user(actor.subject()))
                .header("X-Workspace-Id", actor.workspaceId().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("receiptId", receiptId, "assetId", assetId,
                        "kind", kind, "contentType", contentType, "sizeBytes", sizeBytes, "sha256", sha256))));
    }

    /** Uploads and completes one asset; returns the completion status code. */
    private int upload(Actor actor, String receiptId, String kind, byte[] bytes) throws Exception {
        String assetId = Ids.newId();
        String contentType = bytes[0] == '%' ? "application/pdf" : "image/jpeg";
        JsonNode intent = read(intent(actor, receiptId, assetId, kind, contentType, bytes.length, sha256(bytes))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        put(intent, bytes);
        return complete(actor, receiptId, assetId).andReturn().getResponse().getStatus();
    }

    /** A PDF with {@code count} page objects. */
    static byte[] pages(int count) {
        StringBuilder pdf = new StringBuilder("%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n")
                .append("2 0 obj << /Type /Pages /Count ").append(count).append(" >> endobj\n");
        for (int i = 0; i < count; i++) {
            pdf.append(3 + i).append(" 0 obj << /Type /Page /Parent 2 0 R >> endobj\n");
        }
        return pdf.append("trailer << /Root 1 0 R >>\nstartxref\n0\n%%EOF\n").toString()
                .getBytes(StandardCharsets.US_ASCII);
    }

    private ResultActions complete(Actor actor, String receiptId, String assetId) throws Exception {
        return mvc.perform(post("/v1/receipts/" + receiptId + "/complete").with(user(actor.subject()))
                .header("X-Workspace-Id", actor.workspaceId().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("assetId", assetId))));
    }

    private ResultActions download(Actor actor, String receiptId, String assetId) throws Exception {
        return mvc.perform(get("/v1/receipts/" + receiptId + "/assets/" + assetId + "/download")
                .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString()));
    }

    /** Samples of the extraction latency timer for scan jobs with an outcome. */
    private long extractions(String outcome) {
        Timer timer = meters.find("finance.extraction.latency").tag("job", "receipts.scan").tag("outcome", outcome)
                .timer();
        return timer == null ? 0 : timer.count();
    }

    private int put(JsonNode intent, byte[] bytes) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(intent.path("uploadUrl").asString()))
                .PUT(HttpRequest.BodyPublishers.ofByteArray(bytes));
        intent.path("headers").properties().forEach(h -> request.header(h.getKey(), h.getValue().asString()));
        HttpResponse<String> response = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).as(response.body()).isEqualTo(200);
        return response.statusCode();
    }

    private JsonNode read(String text) {
        return json.readTree(text);
    }

    private static String path(JsonNode intent) {
        return URI.create(intent.path("uploadUrl").asString()).getPath();
    }

    static String sha256(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    static byte[] png() throws Exception {
        return image("png");
    }

    static byte[] jpeg() throws Exception {
        return image("jpg");
    }

    private static byte[] image(String format) throws Exception {
        BufferedImage image = new BufferedImage(40, 30, BufferedImage.TYPE_INT_RGB);
        image.setRGB(3, 4, 0x336699);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(image, format, out);
        return out.toByteArray();
    }

    static byte[] pdf(String content) {
        return ("%PDF-1.4\n1 0 obj << /Type /Catalog " + content + " >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")
                .getBytes(StandardCharsets.US_ASCII);
    }
}
