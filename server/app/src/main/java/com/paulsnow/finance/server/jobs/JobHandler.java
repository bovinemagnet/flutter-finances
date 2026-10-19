package com.paulsnow.finance.server.jobs;

import tools.jackson.databind.JsonNode;

/**
 * Executes one job type. Handlers must be idempotent: a job can run again
 * after a worker crash or a failed attempt. Throwing retries the job with
 * backoff; throwing {@link PermanentJobFailure} fails it at once.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface JobHandler {

    /** Returns the job type this handler runs, for example {@code exports.archive}. */
    String type();

    /**
     * Runs a job.
     *
     * @param job the claimed job
     * @return the result exposed through job status polling (no sensitive data)
     */
    JsonNode handle(Job job);
}
