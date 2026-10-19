package com.paulsnow.finance.server.imports;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;

import com.paulsnow.finance.server.jobs.JobRunner;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;

/**
 * Large batches commit through the background worker and report a job to
 * poll (IMP 01).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@TestPropertySource(properties = "finance.imports.synchronous-row-limit=1")
class ImportJobIntegrationTest extends IntegrationTestSupport {

    @Autowired
    JobRunner runner;

    @Test
    void commitsALargeBatchThroughAJob() throws Exception {
        Actor actor = newActor();
        String bank = createAccount(actor, "transaction");
        String spending = createCategory(actor, "expense");
        String earning = createCategory(actor, "income");
        String csv = "Date,Description,Amount\n01/07/2026,Rent,-1500.00\n02/07/2026,Pay,2000.00\n";
        Map<String, Object> body = Map.of("fileName", "big.csv",
                "contentBase64", Base64.getEncoder().encodeToString(csv.getBytes(StandardCharsets.UTF_8)),
                "mapping", Map.of("id", "m", "name", "m", "accountId", bank, "dateColumn", "Date",
                        "descriptionColumn", "Description", "amountColumn", "Amount"),
                "outflowCategoryId", spending, "inflowCategoryId", earning);
        String batchId = json.readTree(mvc.perform(post("/v1/imports/preview").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString())
                .path("batchId").asString();

        JsonNode accepted = json.readTree(mvc.perform(post("/v1/imports/" + batchId + "/commit")
                        .with(user(actor.subject())).header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isAccepted()).andReturn().getResponse().getContentAsString());
        assertThat(accepted.path("status").asString()).isEqualTo("committing");
        String jobId = accepted.path("jobId").asString();

        runner.runUntilIdle();

        JsonNode job = json.readTree(mvc.perform(get("/v1/jobs/" + jobId).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(job.path("status").asString()).isEqualTo("succeeded");
        assertThat(job.path("result").path("imported").asInt()).isEqualTo(2);
        JsonNode batch = json.readTree(mvc.perform(get("/v1/imports/" + batchId).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(batch.path("status").asString()).isEqualTo("committed");
    }
}
