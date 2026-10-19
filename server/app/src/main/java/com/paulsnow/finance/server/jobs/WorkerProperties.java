package com.paulsnow.finance.server.jobs;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Worker settings ({@code finance.worker.*}).
 *
 * @param enabled      run the polling worker in this process
 * @param pollInterval delay between polls
 * @param batchSize    jobs claimed per poll
 * @param lease        how long a claim lasts before another worker may take over
 * @param maxAttempts  default attempts before a job fails
 * @param baseBackoff  delay after the first failure; doubles each attempt
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.worker")
public record WorkerProperties(boolean enabled, Duration pollInterval, int batchSize, Duration lease,
        int maxAttempts, Duration baseBackoff) {

    public WorkerProperties {
        pollInterval = pollInterval == null ? Duration.ofSeconds(2) : pollInterval;
        batchSize = batchSize <= 0 ? 10 : batchSize;
        lease = lease == null ? Duration.ofMinutes(5) : lease;
        maxAttempts = maxAttempts <= 0 ? 5 : maxAttempts;
        baseBackoff = baseBackoff == null ? Duration.ofSeconds(10) : baseBackoff;
    }
}
