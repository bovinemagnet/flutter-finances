package com.paulsnow.finance.server.audit;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Runs the daily audit retention purge on the worker workload only.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class AuditMaintenance {

    private final AuditLog audit;

    AuditMaintenance(AuditLog audit) {
        this.audit = audit;
    }

    @Scheduled(cron = "${finance.audit.purge-cron:0 37 3 * * *}", zone = "UTC")
    void purge() {
        audit.purgeExpired();
    }
}
