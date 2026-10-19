/**
 * Background work on a PostgreSQL job table: jobs have stable identifiers
 * and pollable status, are claimed with {@code FOR UPDATE SKIP LOCKED} and
 * retried with exponential backoff. The worker loop runs only where
 * {@code finance.worker.enabled} is true, so the API and worker are separate
 * workloads from one codebase.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Jobs")
package com.paulsnow.finance.server.jobs;
