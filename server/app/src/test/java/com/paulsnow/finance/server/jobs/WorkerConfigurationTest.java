package com.paulsnow.finance.server.jobs;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

/**
 * The API and the worker are separate workloads from one codebase: the
 * polling loop exists only when {@code finance.worker.enabled} is true.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class WorkerConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withBean(JobRunner.class, () -> mock(JobRunner.class))
            .withUserConfiguration(WorkerConfiguration.class);

    @Test
    void apiWorkloadHasNoWorkerLoop() {
        runner.run(context -> assertThat(context).doesNotHaveBean(WorkerConfiguration.class));
        runner.withPropertyValues("finance.worker.enabled=false")
                .run(context -> assertThat(context).doesNotHaveBean(WorkerConfiguration.class));
    }

    @Test
    void workerWorkloadPollsTheJobTable() {
        runner.withPropertyValues("finance.worker.enabled=true")
                .run(context -> assertThat(context).hasSingleBean(WorkerConfiguration.class));
    }
}
