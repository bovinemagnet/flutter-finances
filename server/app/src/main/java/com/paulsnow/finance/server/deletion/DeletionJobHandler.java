package com.paulsnow.finance.server.deletion;

import java.sql.Timestamp;
import java.time.Clock;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;
import java.util.function.LongSupplier;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Erases a workspace step by step: stored objects (receipt documents and
 * export archives), each module's metadata and indexes, queued jobs, and
 * finally the workspace with its memberships and devices. Completed steps
 * are recorded and skipped when the job is retried.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class DeletionJobHandler implements JobHandler {

    private static final Logger LOG = LoggerFactory.getLogger(DeletionJobHandler.class);

    private final JdbcClient jdbc;
    private final TransactionTemplate transactions;
    private final ObjectStorage storage;
    private final List<WorkspaceDataPurger> purgers;
    private final JobService jobs;
    private final WorkspaceDirectory workspaces;
    private final JsonMapper json;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    DeletionJobHandler(JdbcClient jdbc, TransactionTemplate transactions, ObjectStorage storage,
            List<WorkspaceDataPurger> purgers, JobService jobs, WorkspaceDirectory workspaces, JsonMapper json,
            Clock clock, ApplicationEventPublisher events) {
        this.jdbc = jdbc;
        this.events = events;
        this.transactions = transactions;
        this.storage = storage;
        this.purgers = purgers.stream().sorted(Comparator.comparingInt(WorkspaceDataPurger::order)).toList();
        this.jobs = jobs;
        this.workspaces = workspaces;
        this.json = json;
        this.clock = clock;
    }

    @Override
    public String type() {
        return DeletionService.DELETION_JOB;
    }

    @Override
    public JsonNode handle(Job job) {
        UUID workspaceId = job.workspaceId();
        UUID deletionId = UUID.fromString(job.payload().path("deletionId").asString());
        step(deletionId, "objects", () -> storage.deletePrefix("workspaces/" + workspaceId + "/"));
        for (WorkspaceDataPurger purger : purgers) {
            step(deletionId, purger.step(), () -> purger.purge(workspaceId));
        }
        step(deletionId, "jobs", () -> jobs.purgeWorkspace(workspaceId, job.id()));
        step(deletionId, "workspace", () -> {
            workspaces.purgeWorkspace(workspaceId);
            return 1;
        });
        jdbc.sql("update deletion_request set status = 'completed', completed_at = ? where id = ?")
                .params(Timestamp.from(clock.instant()), deletionId).update();
        events.publishEvent(AuditEvent.of(workspaceId, null, "workspace.deletion_completed", "deletion",
                deletionId));
        LOG.info("Workspace deletion {} completed", deletionId);
        return JsonNodeFactory.instance.objectNode().put("deletionId", deletionId.toString())
                .put("status", "completed");
    }

    private void step(UUID deletionId, String name, LongSupplier action) {
        transactions.executeWithoutResult(status -> {
            ObjectNode steps = (ObjectNode) json.readTree(jdbc.sql(
                    "select steps from deletion_request where id = ? for update").param(deletionId)
                    .query(String.class).single());
            if (steps.has(name)) {
                return;
            }
            long removed = action.getAsLong();
            steps.putObject(name).put("removed", removed).put("completedAt", clock.instant().toString());
            jdbc.sql("update deletion_request set steps = ?::jsonb where id = ?")
                    .params(json.writeValueAsString(steps), deletionId).update();
        });
    }
}
