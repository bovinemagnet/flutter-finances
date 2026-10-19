package com.paulsnow.finance.server.exports;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import javax.imageio.ImageIO;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import software.amazon.awssdk.services.s3.S3Client;

import tools.jackson.databind.JsonNode;

/**
 * Portable JSON export (EXP 01, DATA 01): a job writes a versioned archive
 * with a manifest of SHA-256 hashes to object storage, and only members of
 * the workspace can download it.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ExportsIntegrationTest extends IntegrationTestSupport {

    private final HttpClient http = HttpClient.newHttpClient();

    @Autowired
    JobRunner jobs;

    @Autowired
    S3Client s3;

    @Test
    void producesAnArchiveWhoseManifestHashesVerify() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String groceries = createCategory(actor, "expense");
        String journalId = Ids.newId();
        submitOne(actor, postJournal(actor, expenseJournal(journalId, bank, groceries, 6325, "posted"), 0));
        String receiptId = Ids.newId();
        submitOne(actor, upsert(actor, "receipt", receiptId, 0, Map.of("status", "captured")));
        byte[] image = png();
        String assetId = upload(actor, receiptId, image);

        JsonNode started = json.readTree(mvc.perform(post("/v1/exports").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"format\":\"json\"}"))
                .andExpect(status().isAccepted())
                .andReturn().getResponse().getContentAsString());
        String exportId = started.path("exportId").asString();
        String jobId = started.path("jobId").asString();

        mvc.perform(get("/v1/exports/" + exportId + "/download").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("EXPORT_NOT_READY"));

        jobs.runUntilIdle();
        mvc.perform(get("/v1/jobs/" + jobId).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("succeeded"))
                .andExpect(jsonPath("$.result.exportId").value(exportId));

        JsonNode link = json.readTree(mvc.perform(get("/v1/exports/" + exportId + "/download")
                        .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        byte[] archive = http.send(HttpRequest.newBuilder(URI.create(link.path("downloadUrl").asString())).build(),
                HttpResponse.BodyHandlers.ofByteArray()).body();

        Map<String, byte[]> files = unzip(archive);
        JsonNode manifest = json.readTree(files.get("manifest.json"));
        assertThat(manifest.path("schemaVersion").asInt()).isEqualTo(1);
        assertThat(manifest.path("workspace").path("currency").asString()).isEqualTo("AUD");
        assertThat(manifest.path("workspace").path("timezone").asString()).isEqualTo("Australia/Brisbane");
        assertThat(manifest.path("acceptedSequence").asLong()).isPositive();
        assertThat(manifest.path("effectiveDates").asString()).contains("timezone");
        for (JsonNode file : manifest.path("files")) {
            byte[] bytes = files.get(file.path("path").asString());
            assertThat(bytes).as(file.path("path").asString()).isNotNull();
            assertThat(sha256(bytes)).isEqualTo(file.path("sha256").asString());
            assertThat((long) bytes.length).isEqualTo(file.path("sizeBytes").asLong());
        }
        assertThat(files.get("receipts/" + receiptId + "/" + assetId)).isEqualTo(image);
        assertThat(manifest.path("counts").path("journal").asInt()).isEqualTo(1);
        assertThat(manifest.path("counts").path("account").asInt()).isEqualTo(1);
        assertThat(manifest.path("counts").path("receiptAssets").asInt()).isEqualTo(1);
        JsonNode journals = json.readTree(files.get("entities/journal.json"));
        assertThat(journals).hasSize(1);
        long sum = 0;
        for (JsonNode posting : journals.get(0).path("data").path("postings")) {
            sum += posting.path("amountMinor").asLong();
        }
        assertThat(sum).isZero();

        Actor stranger = newActor();
        mvc.perform(get("/v1/exports/" + exportId + "/download").with(user(stranger.subject()))
                        .header("X-Workspace-Id", stranger.workspaceId().toString()))
                .andExpect(status().isNotFound());

        // The archive is tagged for the bucket lifecycle, which expires it after
        // the export retention; from then on the export cannot be downloaded.
        assertThat(s3.getObjectTagging(r -> r.bucket("finance-test")
                        .key("workspaces/" + actor.workspaceId() + "/exports/" + exportId + ".zip")).tagSet())
                .anySatisfy(tag -> {
                    assertThat(tag.key()).isEqualTo("finance-retention");
                    assertThat(tag.value()).isEqualTo("export");
                });
        clock.advance(Duration.ofDays(7));
        mvc.perform(get("/v1/exports/" + exportId + "/download").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isGone()).andExpect(jsonPath("$.error").value("EXPORT_EXPIRED"));
    }

    private String upload(Actor actor, String receiptId, byte[] bytes) throws Exception {
        String assetId = Ids.newId();
        JsonNode intent = json.readTree(mvc.perform(post("/v1/receipts/upload-intents")
                        .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("receiptId", receiptId, "assetId", assetId,
                                "kind", "source", "contentType", "image/png", "sizeBytes", bytes.length,
                                "sha256", sha256(bytes)))))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        HttpRequest.Builder put = HttpRequest.newBuilder(URI.create(intent.path("uploadUrl").asString()))
                .PUT(HttpRequest.BodyPublishers.ofByteArray(bytes));
        intent.path("headers").properties().forEach(h -> put.header(h.getKey(), h.getValue().asString()));
        assertThat(http.send(put.build(), HttpResponse.BodyHandlers.discarding()).statusCode()).isEqualTo(200);
        mvc.perform(post("/v1/receipts/" + receiptId + "/complete").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"assetId\":\"" + assetId + "\"}"))
                .andExpect(status().isOk());
        jobs.runUntilIdle();
        return assetId;
    }

    private static Map<String, byte[]> unzip(byte[] archive) throws Exception {
        Map<String, byte[]> files = new HashMap<>();
        try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(archive))) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                files.put(entry.getName(), zip.readAllBytes());
            }
        }
        return files;
    }

    private static String sha256(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static byte[] png() throws Exception {
        BufferedImage image = new BufferedImage(20, 10, BufferedImage.TYPE_INT_RGB);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(image, "png", out);
        return out.toByteArray();
    }
}
