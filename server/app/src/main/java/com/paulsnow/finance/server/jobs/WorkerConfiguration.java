package com.paulsnow.finance.server.jobs;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;

/**
 * The worker workload: polls the job table and enables scheduled
 * maintenance. Absent unless {@code finance.worker.enabled=true}, so an API
 * deployment never runs background work.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
@EnableScheduling
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class WorkerConfiguration {

    private final JobRunner runner;

    WorkerConfiguration(JobRunner runner) {
        this.runner = runner;
    }

    @Scheduled(fixedDelayString = "${finance.worker.poll-interval:2s}")
    void poll() {
        runner.runUntilIdle();
    }
}
