package com.paulsnow.finance.server.deletion;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Accepts workspace deletion requests and reports their progress to the
 * user who asked.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class DeletionService {

    static final String DELETION_JOB = "deletion.workspace";

    /** Deletion progress. */
    record DeletionView(UUID deletionId, UUID workspaceId, UUID jobId, String status, JsonNode steps,
            Instant requestedAt, Instant completedAt) {
    }

    private final JdbcClient jdbc;
    private final WorkspaceDirectory workspaces;
    private final JobService jobs;
    private final JsonMapper json;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    DeletionService(JdbcClient jdbc, WorkspaceDirectory workspaces, JobService jobs, JsonMapper json, Clock clock,
            MeterRegistry meters, ApplicationEventPublisher events) {
        this.jdbc = jdbc;
        this.events = events;
        this.workspaces = workspaces;
        this.jobs = jobs;
        this.json = json;
        this.clock = clock;
        Gauge.builder("finance.deletion.backlog", this::backlog)
                .description("Workspace deletions requested but not yet completed").register(meters);
    }

    /**
     * Starts deleting a workspace. Only an owner may; anyone else learns
     * nothing about the workspace. Repeating the request returns the
     * existing deletion.
     */
    @Transactional
    DeletionView request(CurrentUser user, UUID workspaceId) {
        String role = workspaces.roleOf(user, workspaceId)
                .orElseThrow(() -> ApiException.notFound("WORKSPACE_NOT_FOUND", "Workspace not found."));
        if (!"owner".equals(role)) {
            throw ApiException.forbidden("OWNER_REQUIRED", "Only an owner can delete the workspace.");
        }
        Optional<DeletionView> existing = find(workspaceId);
        if (existing.isPresent()) {
            return existing.get();
        }
        workspaces.beginDeletion(workspaceId);
        UUID deletionId = Ids.newUuid();
        UUID jobId = jobs.enqueue(DELETION_JOB, workspaceId,
                JsonNodeFactory.instance.objectNode().put("deletionId", deletionId.toString()), 20);
        jdbc.sql("insert into deletion_request (id, workspace_id, requested_by, job_id, status, created_at) "
                        + "values (?, ?, ?, ?, 'pending', ?)")
                .params(deletionId, workspaceId, user.id(), jobId, Timestamp.from(clock.instant())).update();
        events.publishEvent(AuditEvent.of(workspaceId, user.id(), "workspace.deletion_requested", "deletion",
                deletionId));
        return find(workspaceId).orElseThrow();
    }

    DeletionView status(CurrentUser user, UUID workspaceId) {
        return jdbc.sql("select * from deletion_request where workspace_id = ? and requested_by = ?")
                .params(workspaceId, user.id()).query(this::map).optional()
                .orElseThrow(() -> ApiException.notFound("DELETION_NOT_FOUND", "No deletion found."));
    }

    Optional<DeletionView> find(UUID workspaceId) {
        return jdbc.sql("select * from deletion_request where workspace_id = ?").param(workspaceId)
                .query(this::map).optional();
    }

    private DeletionView map(java.sql.ResultSet rs, int row) throws java.sql.SQLException {
        Timestamp completed = rs.getTimestamp("completed_at");
        return new DeletionView(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                rs.getObject("job_id", UUID.class), rs.getString("status"), json.readTree(rs.getString("steps")),
                rs.getTimestamp("created_at").toInstant(), completed == null ? null : completed.toInstant());
    }

    private double backlog() {
        try {
            return jdbc.sql("select count(*) from deletion_request where status <> 'completed'").query(Long.class)
                    .single();
        } catch (RuntimeException e) {
            return Double.NaN;
        }
    }
}
