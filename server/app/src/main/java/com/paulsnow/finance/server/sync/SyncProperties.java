package com.paulsnow.finance.server.sync;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Sync settings ({@code finance.sync.*}).
 *
 * @param tombstoneHorizon    how long tombstones and cursors stay valid (SYNC 06)
 * @param maxCommandsPerBatch largest accepted command batch
 * @param maxPageSize         largest change feed or snapshot page
 * @param maxWait             longest a change feed request may be held open (NFR 05)
 * @param waitRecheck         how often a held request re-reads the database
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.sync")
public record SyncProperties(Duration tombstoneHorizon, int maxCommandsPerBatch, int maxPageSize, Duration maxWait,
        Duration waitRecheck) {

    public SyncProperties {
        tombstoneHorizon = tombstoneHorizon == null ? Duration.ofDays(90) : tombstoneHorizon;
        maxCommandsPerBatch = maxCommandsPerBatch <= 0 ? 500 : maxCommandsPerBatch;
        maxPageSize = maxPageSize <= 0 ? 500 : maxPageSize;
        maxWait = maxWait == null ? Duration.ofSeconds(25) : maxWait;
        waitRecheck = waitRecheck == null ? Duration.ofSeconds(2) : waitRecheck;
    }
}
