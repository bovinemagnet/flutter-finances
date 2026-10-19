package com.paulsnow.finance.server.exports;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.storage.PresignedRequest;

import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Starts exports and serves their status and download links, always within
 * the caller's workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class ExportService {

    static final String ARCHIVE_JOB = "exports.archive";

    /** Export status. */
    record ExportView(UUID exportId, UUID jobId, String status, Long sizeBytes, String sha256,
            Long acceptedSequence, Instant createdAt, Instant completedAt) {
    }

    private final JdbcClient jdbc;
    private final JobService jobs;
    private final ObjectStorage storage;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    ExportService(JdbcClient jdbc, JobService jobs, ObjectStorage storage, Clock clock,
            ApplicationEventPublisher events) {
        this.events = events;
        this.jdbc = jdbc;
        this.jobs = jobs;
        this.storage = storage;
        this.clock = clock;
    }

    @Transactional
    ExportView start(UUID workspaceId, UUID requestedBy) {
        UUID exportId = Ids.newUuid();
        UUID jobId = jobs.enqueue(ARCHIVE_JOB, workspaceId,
                JsonNodeFactory.instance.objectNode().put("exportId", exportId.toString())
                        .put("requestedBy", requestedBy.toString()));
        jdbc.sql("insert into export_archive (id, workspace_id, job_id, status, created_at, requested_by) "
                        + "values (?, ?, ?, 'pending', ?, ?)")
                .params(exportId, workspaceId, jobId, Timestamp.from(clock.instant()), requestedBy).update();
        events.publishEvent(AuditEvent.of(workspaceId, requestedBy, "export.requested", "export", exportId));
        return find(workspaceId, exportId);
    }

    ExportView find(UUID workspaceId, UUID exportId) {
        return jdbc.sql("select * from export_archive where id = ? and workspace_id = ?")
                .params(exportId, workspaceId)
                .query((rs, row) -> new ExportView(rs.getObject("id", UUID.class), rs.getObject("job_id", UUID.class),
                        rs.getString("status"), (Long) rs.getObject("size_bytes"),
                        rs.getString("sha256") == null ? null : rs.getString("sha256").trim(),
                        (Long) rs.getObject("accepted_through"), rs.getTimestamp("created_at").toInstant(),
                        rs.getTimestamp("completed_at") == null ? null : rs.getTimestamp("completed_at").toInstant()))
                .optional()
                .orElseThrow(() -> ApiException.notFound("EXPORT_NOT_FOUND", "Export not found."));
    }

    PresignedRequest download(UUID workspaceId, UUID exportId) {
        ExportView export = find(workspaceId, exportId);
        if (!"ready".equals(export.status())) {
            throw ApiException.conflict("EXPORT_NOT_READY", "The export is still being prepared.");
        }
        return storage.presignGet(objectKey(workspaceId, exportId));
    }

    /**
     * Removes a workspace's export records (deletion job); the archives go
     * with the workspace's object prefix.
     *
     * @param workspaceId workspace being deleted
     * @return records removed
     */
    public int purgeWorkspace(UUID workspaceId) {
        return jdbc.sql("delete from export_archive where workspace_id = ?").param(workspaceId).update();
    }

    static String objectKey(UUID workspaceId, UUID exportId) {
        return "workspaces/" + workspaceId + "/exports/" + exportId + ".zip";
    }
}
