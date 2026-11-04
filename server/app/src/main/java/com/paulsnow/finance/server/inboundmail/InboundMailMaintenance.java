package com.paulsnow.finance.server.inboundmail;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;

import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.storage.ObjectStorage;

/**
 * Deletes messages and uncollected documents past their retention, and reports
 * any message still unfinished after an hour as failed, so that it is not lost
 * without the member being able to tell.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundMailMaintenance {

    private static final Duration STUCK_AFTER = Duration.ofHours(1);

    private final InboundMessageStore messages;
    private final ObjectStorage storage;
    private final Clock clock;

    InboundMailMaintenance(InboundMessageStore messages, ObjectStorage storage, Clock clock) {
        this.messages = messages;
        this.storage = storage;
        this.clock = clock;
    }

    @Scheduled(cron = "${finance.inbound-mail.purge-cron:0 17 * * * *}", zone = "UTC")
    void sweep() {
        Instant now = clock.instant();
        messages.failStuck(now.minus(STUCK_AFTER));
        messages.purgeExpired(now, storage);
    }
}
