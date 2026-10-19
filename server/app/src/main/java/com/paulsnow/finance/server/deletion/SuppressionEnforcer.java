package com.paulsnow.finance.server.deletion;

import java.util.Comparator;
import java.util.List;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

/**
 * Keeps deleted workspaces deleted (SEC 06). A database backup taken
 * before a deletion and restored afterwards brings the workspace back,
 * while its deletion suppression record (kept with the restore procedure)
 * still names it. The API already refuses such a workspace; this erases it
 * again: devices are revoked, stored objects removed and every module's
 * purger, the job queue and the workspace rows run once more. Every step
 * is idempotent.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class SuppressionEnforcer {

    private static final Logger LOG = LoggerFactory.getLogger(SuppressionEnforcer.class);

    private final JdbcClient jdbc;
    private final WorkspaceDirectory workspaces;
    private final ObjectStorage storage;
    private final List<WorkspaceDataPurger> purgers;
    private final JobService jobs;
    private final TransactionTemplate transactions;
    private final Counter reapplied;

    SuppressionEnforcer(JdbcClient jdbc, WorkspaceDirectory workspaces, ObjectStorage storage,
            List<WorkspaceDataPurger> purgers, JobService jobs, TransactionTemplate transactions,
            MeterRegistry meters) {
        this.jdbc = jdbc;
        this.workspaces = workspaces;
        this.storage = storage;
        this.purgers = purgers.stream().sorted(Comparator.comparingInt(WorkspaceDataPurger::order)).toList();
        this.jobs = jobs;
        this.transactions = transactions;
        this.reapplied = Counter.builder("finance.deletion.suppression.reapplied")
                .description("Deleted workspaces found again (for example after a restore) and erased again")
                .register(meters);
    }

    /**
     * Erases every suppressed workspace that has rows again.
     *
     * @return workspaces erased
     */
    int enforce() {
        List<UUID> found = workspaces.suppressedButPresent();
        for (UUID workspaceId : found) {
            LOG.warn("Deleted workspace {} is present again; erasing it again", workspaceId);
            transactions.executeWithoutResult(status -> workspaces.beginDeletion(workspaceId));
            storage.deletePrefix("workspaces/" + workspaceId + "/");
            for (WorkspaceDataPurger purger : purgers) {
                transactions.executeWithoutResult(status -> purger.purge(workspaceId));
            }
            // No job is kept: none of the restored jobs may run.
            transactions.executeWithoutResult(status -> jobs.purgeWorkspace(workspaceId, Ids.newUuid()));
            transactions.executeWithoutResult(status -> {
                workspaces.purgeWorkspace(workspaceId);
                jdbc.sql("update deletion_request set status = 'completed', completed_at = now() "
                        + "where workspace_id = ? and status <> 'completed'").param(workspaceId).update();
            });
            reapplied.increment();
        }
        return found.size();
    }
}
