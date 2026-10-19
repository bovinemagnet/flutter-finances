package com.paulsnow.finance.server.jobs;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import com.paulsnow.finance.core.ids.Ids;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * Queues jobs and reports their status. Enqueuing joins the caller's
 * transaction, so a job is only visible once the work that requested it has
 * committed (transactional outbox).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class JobService {

    private final JdbcClient jdbc;
    private final Clock clock;
    private final WorkerProperties properties;
    private final JsonMapper json;

    JobService(JdbcClient jdbc, Clock clock, WorkerProperties properties, JsonMapper json, MeterRegistry meters) {
        this.jdbc = jdbc;
        this.clock = clock;
        this.properties = properties;
        this.json = json;
        Gauge.builder("finance.jobs.backlog", () -> count("select count(*) from job where status in "
                        + "('queued', 'running')"))
                .description("Jobs waiting or running").register(meters);
        Gauge.builder("finance.jobs.backlog.age", this::oldestQueuedAgeSeconds)
                .description("Age of the oldest queued job").baseUnit("seconds").register(meters);
    }

    /**
     * Queues a job with the default number of attempts.
     *
     * @param type        handler type
     * @param workspaceId owning workspace, or null
     * @param payload     handler input (identifiers only, no financial data)
     * @return the job identifier
     */
    public UUID enqueue(String type, UUID workspaceId, JsonNode payload) {
        return enqueue(type, workspaceId, payload, properties.maxAttempts());
    }

    /**
     * Queues a job.
     *
     * @param type        handler type
     * @param workspaceId owning workspace, or null
     * @param payload     handler input
     * @param maxAttempts attempts before the job fails
     * @return the job identifier
     */
    public UUID enqueue(String type, UUID workspaceId, JsonNode payload, int maxAttempts) {
        return enqueueAt(type, workspaceId, payload, maxAttempts, clock.instant());
    }

    /**
     * Queues a job that is not claimed before {@code runAfter}, for example
     * a retry the handler schedules itself after a provider rate limit.
     *
     * @param type        handler type
     * @param workspaceId owning workspace, or null
     * @param payload     handler input
     * @param maxAttempts attempts before the job fails
     * @param runAfter    earliest time the job runs
     * @return the job identifier
     */
    public UUID enqueueAt(String type, UUID workspaceId, JsonNode payload, int maxAttempts, Instant runAfter) {
        UUID id = Ids.newUuid();
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("insert into job (id, workspace_id, type, status, payload, attempts, max_attempts, run_after, "
                        + "created_at, updated_at) values (?, ?, ?, 'queued', ?::jsonb, 0, ?, ?, ?, ?)")
                .params(id, workspaceId, type, json.writeValueAsString(payload), maxAttempts,
                        Timestamp.from(runAfter), now, now)
                .update();
        return id;
    }

    /**
     * Returns a job of the workspace; another workspace's job is never found.
     *
     * @param workspaceId caller's workspace
     * @param jobId       job
     * @return the status
     */
    public Optional<JobView> find(UUID workspaceId, UUID jobId) {
        return jdbc.sql("select * from job where id = ? and workspace_id = ?").params(jobId, workspaceId)
                .query(this::map).optional();
    }

    /**
     * Returns a job regardless of workspace, for modules that authorise
     * access themselves (for example deletion status after the workspace is
     * gone).
     *
     * @param jobId job
     * @return the status
     */
    public Optional<JobView> findAny(UUID jobId) {
        return jdbc.sql("select * from job where id = ?").param(jobId).query(this::map).optional();
    }

    /**
     * Removes a workspace's jobs other than {@code keep} (deletion job).
     *
     * @param workspaceId workspace being deleted
     * @param keep        job to keep, typically the running deletion job
     * @return jobs removed
     */
    public int purgeWorkspace(UUID workspaceId, UUID keep) {
        return jdbc.sql("delete from job where workspace_id = ? and id <> ?").params(workspaceId, keep).update();
    }

    private JobView map(ResultSet rs, int row) throws SQLException {
        String result = rs.getString("result");
        return new JobView(rs.getObject("id", UUID.class), rs.getString("type"), rs.getString("status"),
                rs.getInt("attempts"), result == null ? null : json.readTree(result),
                "failed".equals(rs.getString("status")) ? rs.getString("last_error") : null,
                instant(rs, "created_at"), instant(rs, "updated_at"), instant(rs, "completed_at"));
    }

    private double count(String sql) {
        try {
            return jdbc.sql(sql).query(Long.class).single();
        } catch (RuntimeException e) {
            return Double.NaN;
        }
    }

    private double oldestQueuedAgeSeconds() {
        try {
            Optional<Timestamp> oldest = jdbc.sql("select min(run_after) from job where status = 'queued'")
                    .query(Timestamp.class).optional();
            return oldest.map(t -> Math.max(0, clock.millis() - t.getTime()) / 1000.0).orElse(0.0);
        } catch (RuntimeException e) {
            return Double.NaN;
        }
    }

    private static Instant instant(ResultSet rs, String column) throws SQLException {
        Timestamp value = rs.getTimestamp(column);
        return value == null ? null : value.toInstant();
    }
}
