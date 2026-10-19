package com.paulsnow.finance.server.sync;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Runs the daily tombstone purge on the worker workload only.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class SyncMaintenance {

    private final TombstonePurger purger;

    SyncMaintenance(TombstonePurger purger) {
        this.purger = purger;
    }

    @Scheduled(cron = "${finance.sync.purge-cron:0 17 3 * * *}", zone = "UTC")
    void purgeTombstones() {
        purger.purgeExpiredTombstones();
    }
}
