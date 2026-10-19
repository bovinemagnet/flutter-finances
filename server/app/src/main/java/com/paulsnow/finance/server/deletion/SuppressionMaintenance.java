package com.paulsnow.finance.server.deletion;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Runs {@link SuppressionEnforcer} on the worker workload: once at startup,
 * which is when a restored database first comes up, and then periodically.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class SuppressionMaintenance {

    private final SuppressionEnforcer enforcer;

    SuppressionMaintenance(SuppressionEnforcer enforcer) {
        this.enforcer = enforcer;
    }

    @EventListener(ApplicationReadyEvent.class)
    void atStartup() {
        enforcer.enforce();
    }

    @Scheduled(cron = "${finance.deletion.suppression-cron:0 */15 * * * *}", zone = "UTC")
    void periodically() {
        enforcer.enforce();
    }
}
