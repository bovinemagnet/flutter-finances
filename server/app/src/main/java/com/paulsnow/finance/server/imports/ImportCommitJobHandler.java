package com.paulsnow.finance.server.imports;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;
import com.paulsnow.finance.server.jobs.PermanentJobFailure;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import tools.jackson.databind.JsonNode;

/**
 * Commits a large import batch on the worker. Safe to run again: the
 * committer replays the same commands.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ImportCommitJobHandler implements JobHandler {

    static final String TYPE = "imports.commit";

    private final ImportRepository repository;
    private final ImportCommitter committer;
    private final WorkspaceDirectory workspaces;

    ImportCommitJobHandler(ImportRepository repository, ImportCommitter committer, WorkspaceDirectory workspaces) {
        this.repository = repository;
        this.committer = committer;
        this.workspaces = workspaces;
    }

    @Override
    public String type() {
        return TYPE;
    }

    @Override
    public JsonNode handle(Job job) {
        WorkspaceInfo workspace = workspaces.findActive(job.workspaceId())
                .orElseThrow(() -> new PermanentJobFailure("WORKSPACE_UNAVAILABLE"));
        ImportRepository.Batch batch = repository
                .find(workspace.id(), UUID.fromString(job.payload().path("batchId").asString()))
                .orElseThrow(() -> new PermanentJobFailure("IMPORT_NOT_FOUND"));
        if ("committed".equals(batch.status())) {
            return batch.result();
        }
        return committer.commit(workspace, batch);
    }
}
