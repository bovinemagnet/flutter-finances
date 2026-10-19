package com.paulsnow.finance.server.deletion;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
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
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import javax.imageio.ImageIO;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;

/**
 * Workspace deletion (SEC 05, SEC 06): access ends at once, a tracked job
 * erases metadata, documents and indexes, and a suppression record stops
 * the workspace from being reintroduced.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class WorkspaceDeletionIntegrationTest extends IntegrationTestSupport {

    private static final List<String> WORKSPACE_TABLES = List.of("sync_entity", "sync_change", "sync_idempotency",
            "sync_device_cursor", "ledger_journal", "ledger_posting", "receipt_document", "receipt_asset",
            "export_archive", "import_batch", "import_row", "membership", "device");

    @Autowired
    JobRunner jobs;

    @Autowired
    JdbcClient jdbc;

    @Autowired
    ObjectStorage storage;

    @Test
    void deletesEverythingAndSuppressesTheWorkspace() throws Exception {
        Actor owner = newActor();
        String bank = createAccount(owner, "transaction");
        String groceries = createCategory(owner, "expense");
        submitOne(owner, postJournal(owner, expenseJournal(Ids.newId(), bank, groceries, 6325, "posted"), 0));
        changes(owner, null);
        String receiptId = Ids.newId();
        submitOne(owner, upsert(owner, "receipt", receiptId, 0, Map.of("status", "captured")));
        String objectKey = uploadReceipt(owner, receiptId);
        mvc.perform(post("/v1/exports").with(user(owner.subject()))
                .header("X-Workspace-Id", owner.workspaceId().toString())).andExpect(status().isAccepted());
        String income = createCategory(owner, "income");
        String csv = "Date,Description,Amount\n01/07/2026,Rent,-1.00\n";
        mvc.perform(post("/v1/imports/preview").with(user(owner.subject()))
                        .header("X-Workspace-Id", owner.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("fileName", "statement.csv",
                                "contentBase64", java.util.Base64.getEncoder().encodeToString(csv.getBytes()),
                                "mapping", Map.of("id", "m1", "name", "Bank", "accountId", bank,
                                        "dateColumn", "Date", "descriptionColumn", "Description",
                                        "amountColumn", "Amount"),
                                "outflowCategoryId", groceries, "inflowCategoryId", income))))
                .andExpect(status().isOk());
        jobs.runUntilIdle();
        assertThat(storage.head(objectKey)).isPresent();

        Actor stranger = newActor();
        mvc.perform(delete("/v1/workspaces/" + owner.workspaceId()).with(user(stranger.subject())))
                .andExpect(status().isNotFound());

        JsonNode started = json.readTree(mvc.perform(delete("/v1/workspaces/" + owner.workspaceId())
                        .with(user(owner.subject())))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.status").value("pending"))
                .andReturn().getResponse().getContentAsString());

        // Access ends before the job runs: devices are revoked and the
        // workspace is hidden.
        mvc.perform(get("/v1/workspaces/" + owner.workspaceId()).with(user(owner.subject())))
                .andExpect(status().isNotFound());
        mvc.perform(get("/v1/sync/changes").with(user(owner.subject()))
                        .header("X-Device-Id", owner.deviceId().toString()))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("DEVICE_REVOKED"));

        jobs.runUntilIdle();

        mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/deletion").with(user(owner.subject())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.deletionId").value(started.path("deletionId").asString()))
                .andExpect(jsonPath("$.status").value("completed"))
                .andExpect(jsonPath("$.steps.objects").exists())
                .andExpect(jsonPath("$.steps.sync").exists())
                .andExpect(jsonPath("$.steps.ledger").exists())
                .andExpect(jsonPath("$.steps.workspace").exists());
        mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/deletion").with(user(stranger.subject())))
                .andExpect(status().isNotFound());

        for (String table : WORKSPACE_TABLES) {
            assertThat(jdbc.sql("select count(*) from " + table + " where workspace_id = ?")
                    .param(owner.workspaceId()).query(Long.class).single()).as(table).isZero();
        }
        assertThat(jdbc.sql("select count(*) from workspace where id = ?").param(owner.workspaceId())
                .query(Long.class).single()).isZero();
        assertThat(storage.head(objectKey)).isEmpty();

        // A restored backup or replayed bootstrap cannot reintroduce it.
        mvc.perform(post("/v1/workspaces").with(user(owner.subject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("id", owner.workspaceId().toString(),
                                "name", "Restored", "currency", "AUD", "timezone", "Australia/Brisbane"))))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("WORKSPACE_DELETED"));
    }

    @Test
    void onlyAnOwnerCanDelete() throws Exception {
        Actor owner = newActor();
        mvc.perform(delete("/v1/workspaces/" + UUID.randomUUID()).with(user(owner.subject())))
                .andExpect(status().isNotFound());
    }

    private String uploadReceipt(Actor actor, String receiptId) throws Exception {
        BufferedImage image = new BufferedImage(8, 8, BufferedImage.TYPE_INT_RGB);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(image, "png", out);
        byte[] bytes = out.toByteArray();
        String assetId = Ids.newId();
        String sha = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        JsonNode intent = json.readTree(mvc.perform(post("/v1/receipts/upload-intents")
                        .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("receiptId", receiptId, "assetId", assetId,
                                "kind", "source", "contentType", "image/png", "sizeBytes", bytes.length,
                                "sha256", sha))))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        HttpRequest.Builder put = HttpRequest.newBuilder(URI.create(intent.path("uploadUrl").asString()))
                .PUT(HttpRequest.BodyPublishers.ofByteArray(bytes));
        intent.path("headers").properties().forEach(h -> put.header(h.getKey(), h.getValue().asString()));
        HttpClient.newHttpClient().send(put.build(), HttpResponse.BodyHandlers.discarding());
        mvc.perform(post("/v1/receipts/" + receiptId + "/complete").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"assetId\":\"" + assetId + "\"}"))
                .andExpect(status().isOk());
        return "workspaces/" + actor.workspaceId() + "/receipts/" + receiptId + "/" + assetId;
    }
}
