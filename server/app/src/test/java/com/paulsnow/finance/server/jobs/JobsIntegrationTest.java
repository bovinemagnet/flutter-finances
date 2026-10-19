package com.paulsnow.finance.server.jobs;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;

import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * The PostgreSQL job table: claiming, completion, retries with backoff,
 * permanent failure and workspace-scoped status polling.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Import(JobsIntegrationTest.TestHandlers.class)
class JobsIntegrationTest extends IntegrationTestSupport {

    static final AtomicInteger FLAKY_CALLS = new AtomicInteger();

    @TestConfiguration(proxyBeanMethods = false)
    static class TestHandlers {

        @Bean
        JobHandler echoHandler() {
            return new JobHandler() {
                @Override
                public String type() {
                    return "test.echo";
                }

                @Override
                public JsonNode handle(Job job) {
                    return JsonNodeFactory.instance.objectNode().put("echo", job.payload().path("value").asString());
                }
            };
        }

        @Bean
        JobHandler flakyHandler() {
            return new JobHandler() {
                @Override
                public String type() {
                    return "test.flaky";
                }

                @Override
                public JsonNode handle(Job job) {
                    if (FLAKY_CALLS.incrementAndGet() < 2) {
                        throw new IllegalStateException("transient");
                    }
                    return JsonNodeFactory.instance.objectNode().put("attempt", job.attempt());
                }
            };
        }

        @Bean
        JobHandler brokenHandler() {
            return new JobHandler() {
                @Override
                public String type() {
                    return "test.broken";
                }

                @Override
                public JsonNode handle(Job job) {
                    throw new PermanentJobFailure("INPUT_REJECTED");
                }
            };
        }
    }

    @Autowired
    JobService jobs;

    @Autowired
    JobRunner runner;

    @Autowired
    JdbcClient jdbc;

    @Test
    void runsAJobAndReportsItsResultToMembersOnly() throws Exception {
        Actor actor = newActor();
        UUID jobId = jobs.enqueue("test.echo", actor.workspaceId(),
                JsonNodeFactory.instance.objectNode().put("value", "hello"));
        mvc.perform(get("/v1/jobs/" + jobId).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("queued"));

        runner.runUntilIdle();

        mvc.perform(get("/v1/jobs/" + jobId).with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(jobId.toString()))
                .andExpect(jsonPath("$.status").value("succeeded"))
                .andExpect(jsonPath("$.result.echo").value("hello"));

        Actor stranger = newActor();
        mvc.perform(get("/v1/jobs/" + jobId).with(user(stranger.subject()))
                        .header("X-Workspace-Id", stranger.workspaceId().toString()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("JOB_NOT_FOUND"));
    }

    @Test
    void retriesWithBackoffThenSucceeds() {
        FLAKY_CALLS.set(0);
        UUID jobId = jobs.enqueue("test.flaky", null, JsonNodeFactory.instance.objectNode());
        runner.runUntilIdle();
        assertThat(statusOf(jobId)).isEqualTo("queued");
        assertThat(jdbc.sql("select attempts from job where id = ?").param(jobId).query(Integer.class).single())
                .isEqualTo(1);

        runner.runUntilIdle();
        assertThat(statusOf(jobId)).as("not due before the backoff").isEqualTo("queued");

        clock.advance(Duration.ofMinutes(5));
        runner.runUntilIdle();
        assertThat(statusOf(jobId)).isEqualTo("succeeded");
    }

    @Test
    void failsPermanentlyWithoutRetrying() {
        UUID jobId = jobs.enqueue("test.broken", null, JsonNodeFactory.instance.objectNode());
        runner.runUntilIdle();
        assertThat(statusOf(jobId)).isEqualTo("failed");
        assertThat(jdbc.sql("select last_error from job where id = ?").param(jobId).query(String.class).single())
                .isEqualTo("INPUT_REJECTED");
    }

    @Test
    void reclaimsJobsWhoseWorkerLeaseExpired() {
        UUID jobId = jobs.enqueue("test.echo", null, JsonNodeFactory.instance.objectNode().put("value", "x"));
        jdbc.sql("update job set status = 'running', locked_by = 'crashed', locked_until = ? where id = ?")
                .params(java.sql.Timestamp.from(clock.instant().minusSeconds(1)), jobId).update();
        runner.runUntilIdle();
        assertThat(statusOf(jobId)).isEqualTo("succeeded");
    }

    private String statusOf(UUID jobId) {
        return jdbc.sql("select status from job where id = ?").param(jobId).query(String.class).single();
    }
}
