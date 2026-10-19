package com.paulsnow.finance.server.jobs;

import java.net.InetAddress;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.common.CorrelationIds;
import com.paulsnow.finance.server.common.Redactor;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Claims due jobs with {@code FOR UPDATE SKIP LOCKED}, so several workers
 * never run the same job, and records the outcome. A job whose lease has
 * expired (the worker died) is claimed again.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
public class JobRunner {

    private static final Logger LOG = LoggerFactory.getLogger(JobRunner.class);

    private final JdbcClient jdbc;
    private final Clock clock;
    private final WorkerProperties properties;
    private final JsonMapper json;
    private final Map<String, JobHandler> handlers;
    private final String workerId;

    JobRunner(JdbcClient jdbc, Clock clock, WorkerProperties properties, JsonMapper json, List<JobHandler> handlers) {
        this.jdbc = jdbc;
        this.clock = clock;
        this.properties = properties;
        this.json = json;
        this.handlers = handlers.stream().collect(Collectors.toMap(JobHandler::type, Function.identity()));
        this.workerId = hostName() + "-" + UUID.randomUUID();
    }

    /**
     * Claims and runs one batch of due jobs.
     *
     * @return number of jobs run
     */
    public int runDueJobs() {
        List<Job> claimed = claim();
        for (Job job : claimed) {
            CorrelationIds.runWith("job-" + job.id(), () -> run(job));
        }
        return claimed.size();
    }

    /** Runs due jobs until none are left, for tests and one-off maintenance. */
    public void runUntilIdle() {
        int guard = 0;
        while (runDueJobs() > 0 && guard++ < 1000) {
            // Keep draining.
        }
    }

    private List<Job> claim() {
        Instant now = clock.instant();
        return jdbc.sql("update job set status = 'running', attempts = attempts + 1, locked_by = ?, "
                        + "locked_until = ?, updated_at = ? where id in (select id from job where "
                        + "(status = 'queued' and run_after <= ?) or (status = 'running' and locked_until < ?) "
                        + "order by run_after limit ? for update skip locked) "
                        + "returning id, workspace_id, type, payload, attempts")
                .params(workerId, Timestamp.from(now.plus(properties.lease())), Timestamp.from(now),
                        Timestamp.from(now), Timestamp.from(now), properties.batchSize())
                .query((rs, row) -> new Job(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                        rs.getString("type"), json.readTree(rs.getString("payload")), rs.getInt("attempts")))
                .list();
    }

    private void run(Job job) {
        JobHandler handler = handlers.get(job.type());
        if (handler == null) {
            fail(job, "NO_HANDLER", true);
            return;
        }
        try {
            JsonNode result = handler.handle(job);
            jdbc.sql("update job set status = 'succeeded', result = ?::jsonb, locked_by = null, locked_until = null, "
                            + "last_error = null, updated_at = ?, completed_at = ? where id = ? and locked_by = ?")
                    .params(json.writeValueAsString(result == null ? JsonNodeFactory.instance.objectNode() : result),
                            Timestamp.from(clock.instant()), Timestamp.from(clock.instant()), job.id(), workerId)
                    .update();
        } catch (PermanentJobFailure e) {
            fail(job, e.getMessage(), true);
        } catch (RuntimeException e) {
            LOG.warn("Job {} of type {} failed on attempt {}", job.id(), job.type(), job.attempt(), e);
            fail(job, e.getClass().getSimpleName(), false);
        }
    }

    private void fail(Job job, String error, boolean permanent) {
        Instant now = clock.instant();
        Duration backoff = properties.baseBackoff().multipliedBy(1L << Math.min(job.attempt() - 1, 16));
        String safeError = Redactor.redact(error);
        if (safeError != null && safeError.length() > 500) {
            safeError = safeError.substring(0, 500);
        }
        jdbc.sql("update job set status = case when ?::boolean or attempts >= max_attempts then 'failed' else 'queued' end, "
                        + "run_after = ?, last_error = ?, locked_by = null, locked_until = null, updated_at = ?, "
                        + "completed_at = case when ?::boolean or attempts >= max_attempts then ?::timestamptz else null end "
                        + "where id = ? and locked_by = ?")
                .params(permanent, Timestamp.from(now.plus(backoff)), safeError, Timestamp.from(now), permanent,
                        Timestamp.from(now), job.id(), workerId)
                .update();
    }

    private static String hostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return "worker";
        }
    }
}
