package com.paulsnow.finance.server.sync;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * Compacts the change log after the tombstone horizon (SYNC 06):
 * <ul>
 * <li>change records older than the horizon that a later change of the same
 * entity supersedes are removed;</li>
 * <li>delete records older than the horizon are removed and the highest
 * removed sequence becomes the workspace's purge watermark, so any cursor
 * before it is expired;</li>
 * <li>tombstoned entities keep their row, without data, so that no pending
 * command can ever resurrect them.</li>
 * </ul>
 * The latest change of every live entity is always kept, so a client with
 * an empty cursor can still rebuild from the feed.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
public class TombstonePurger {

    private static final Logger LOG = LoggerFactory.getLogger(TombstonePurger.class);

    private final JdbcClient jdbc;
    private final SyncProperties properties;
    private final Clock clock;

    TombstonePurger(JdbcClient jdbc, SyncProperties properties, Clock clock) {
        this.jdbc = jdbc;
        this.properties = properties;
        this.clock = clock;
    }

    /** Runs one compaction pass over every workspace. */
    @Transactional
    public void purgeExpiredTombstones() {
        // Database timestamps hold microseconds, as do cursors.
        Instant now = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.MICROS);
        Timestamp cutoff = Timestamp.from(now.minus(properties.tombstoneHorizon()));
        int superseded = jdbc.sql("delete from sync_change c where c.created_at < ? and exists (select 1 from "
                        + "sync_change n where n.workspace_id = c.workspace_id and n.entity_id = c.entity_id "
                        + "and n.sequence > c.sequence)")
                .param(cutoff).update();
        int tombstones = jdbc.sql("with purged as (delete from sync_change where op = 'delete' and created_at < ? "
                        + "returning workspace_id, sequence) insert into sync_purge_watermark (workspace_id, "
                        + "purged_through, purged_at) select workspace_id, max(sequence), ? from purged "
                        + "group by workspace_id on conflict (workspace_id) do update set purged_through = "
                        + "greatest(sync_purge_watermark.purged_through, excluded.purged_through), "
                        + "purged_at = excluded.purged_at")
                .params(cutoff, Timestamp.from(now)).update();
        int compacted = jdbc.sql("update sync_entity set data = null, field_revisions = '{}'::jsonb "
                        + "where deleted and deleted_at < ? and data is not null")
                .param(cutoff).update();
        LOG.info("Tombstone purge removed {} superseded changes, updated {} watermarks, compacted {} entities",
                superseded, tombstones, compacted);
    }
}
