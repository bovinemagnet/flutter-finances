package com.paulsnow.finance.server.jobs;

import java.util.UUID;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Job status polling, scoped to the caller's workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Jobs")
class JobController {

    private final JobService jobs;

    JobController(JobService jobs) {
        this.jobs = jobs;
    }

    @GetMapping("/v1/jobs/{jobId}")
    @Operation(summary = "Poll a job's status and result")
    JobView get(CurrentMember member, @PathVariable UUID jobId) {
        return jobs.find(member.workspaceId(), jobId)
                .orElseThrow(() -> ApiException.notFound("JOB_NOT_FOUND", "Job not found."));
    }
}
