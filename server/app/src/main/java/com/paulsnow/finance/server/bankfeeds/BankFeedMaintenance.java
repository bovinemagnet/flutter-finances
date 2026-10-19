package com.paulsnow.finance.server.bankfeeds;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Removes old webhook delivery records on the worker workload only.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class BankFeedMaintenance {

    private final WebhookReceiver webhooks;

    BankFeedMaintenance(WebhookReceiver webhooks) {
        this.webhooks = webhooks;
    }

    @Scheduled(cron = "${finance.bank-feeds.purge-cron:0 47 * * * *}", zone = "UTC")
    void purgeDeliveries() {
        webhooks.purgeDeliveries();
    }
}
