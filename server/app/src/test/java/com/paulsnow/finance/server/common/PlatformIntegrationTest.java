package com.paulsnow.finance.server.common;

import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.matchesPattern;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.paulsnow.finance.server.support.IntegrationTestSupport;

/**
 * Cross-cutting behaviour: authentication, error model, correlation
 * identifiers, health, metrics and the OpenAPI document.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class PlatformIntegrationTest extends IntegrationTestSupport {

    @Test
    void rejectsUnauthenticatedApiCallsWithTheErrorModel() throws Exception {
        mvc.perform(get("/v1/workspaces"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error").value("UNAUTHENTICATED"))
                .andExpect(header().string("X-Correlation-Id", matchesPattern("[0-9a-f-]{36}")));
    }

    @Test
    void echoesAWellFormedCorrelationIdAndReplacesAMalformedOne() throws Exception {
        mvc.perform(get("/v1/workspaces").with(user(newSubject())).header("X-Correlation-Id", "abc-123"))
                .andExpect(status().isOk())
                .andExpect(header().string("X-Correlation-Id", "abc-123"));
        mvc.perform(get("/v1/workspaces").with(user(newSubject())).header("X-Correlation-Id", "bad id\n<script>"))
                .andExpect(header().string("X-Correlation-Id", matchesPattern("[0-9a-f-]{36}")));
    }

    @Test
    void reportsUnknownWorkspacesAsNotFoundWithCorrelationId() throws Exception {
        mvc.perform(get("/v1/workspaces/" + UUID.randomUUID()).with(user(newSubject())))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("WORKSPACE_NOT_FOUND"))
                .andExpect(jsonPath("$.correlationId").isNotEmpty());
    }

    @Test
    void exposesHealthWithoutAuthentication() throws Exception {
        mvc.perform(get("/actuator/health")).andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void exposesOperationalMetrics() throws Exception {
        mvc.perform(get("/actuator/prometheus")).andExpect(status().isOk())
                .andExpect(content().string(containsString("finance_sync_backlog_age_seconds")))
                .andExpect(content().string(containsString("finance_sync_commands")))
                .andExpect(content().string(containsString("finance_ledger_journals_rejected")))
                .andExpect(content().string(containsString("finance_receipts_upload_failures")))
                .andExpect(content().string(containsString("finance_imports_failures")))
                .andExpect(content().string(containsString("finance_jobs_backlog")))
                .andExpect(content().string(containsString("finance_deletion_backlog")));
    }

    @Test
    void publishesTheOpenApiDocument() throws Exception {
        mvc.perform(get("/v3/api-docs")).andExpect(status().isOk())
                .andExpect(jsonPath("$.paths['/v1/sync/commands']").exists())
                .andExpect(jsonPath("$.paths['/v1/sync/changes']").exists())
                .andExpect(jsonPath("$.paths['/v1/sync/snapshot']").exists())
                .andExpect(jsonPath("$.paths['/v1/receipts/upload-intents']").exists())
                .andExpect(jsonPath("$.paths['/v1/receipts/{receiptId}/complete']").exists())
                .andExpect(jsonPath("$.paths['/v1/receipts/{receiptId}/assets/{assetId}/download']").exists())
                .andExpect(jsonPath("$.paths['/v1/imports/preview']").exists())
                .andExpect(jsonPath("$.paths['/v1/imports/{batchId}/commit']").exists())
                .andExpect(jsonPath("$.paths['/v1/exports']").exists())
                .andExpect(jsonPath("$.paths['/v1/jobs/{jobId}']").exists())
                .andExpect(jsonPath("$.paths['/v1/devices']").exists())
                .andExpect(jsonPath("$.paths['/v1/workspaces']").exists());
    }
}
