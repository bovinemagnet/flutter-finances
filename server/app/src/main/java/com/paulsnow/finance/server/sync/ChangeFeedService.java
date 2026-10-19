package com.paulsnow.finance.server.sync;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentDevice;

import tools.jackson.databind.JsonNode;

/**
 * The ordered change feed and paged snapshots (SYNC 04, SYNC 06).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class ChangeFeedService {

    /** One change in the feed; {@code data} is the entity at that revision, null for deletes. */
    record ChangeView(String entityType, UUID entityId, long revision, String op, JsonNode data) {
    }

    /** A page of the feed. */
    record ChangePage(List<ChangeView> changes, String cursor, boolean hasMore) {
    }

    /** One live entity in a snapshot. */
    record SnapshotEntity(String entityType, UUID entityId, long revision, JsonNode data) {
    }

    /**
     * A page of a snapshot. Keep the {@code cursor} of the first page and
     * continue the feed from it after the last page.
     */
    record SnapshotPage(List<SnapshotEntity> entities, String after, boolean hasMore, String cursor) {
    }

    private final JdbcClient jdbc;
    private final EntityStore store;
    private final SyncProperties properties;
    private final Clock clock;

    ChangeFeedService(JdbcClient jdbc, EntityStore store, SyncProperties properties, Clock clock) {
        this.jdbc = jdbc;
        this.store = store;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional
    ChangePage changes(CurrentDevice device, String cursorText, Integer limit) {
        UUID workspaceId = device.workspaceId();
        int pageSize = pageSize(limit);
        long after = 0;
        Instant now = clock.instant();
        if (cursorText != null && !cursorText.isBlank()) {
            CursorCodec.Cursor cursor = CursorCodec.decode(cursorText.strip(), workspaceId);
            after = cursor.sequence();
            if (after > 0 && (cursor.issuedAt().plus(properties.tombstoneHorizon()).isBefore(now)
                    || missedPurge(workspaceId, cursor))) {
                throw ApiException.gone("CURSOR_EXPIRED",
                        "This cursor is older than the tombstone horizon; rebuild from a snapshot.");
            }
        }
        List<EntityStore.Change> rows = store.changesAfter(workspaceId, after, pageSize + 1);
        boolean hasMore = rows.size() > pageSize;
        List<ChangeView> changes = new ArrayList<>();
        long last = after;
        for (EntityStore.Change change : rows.subList(0, Math.min(pageSize, rows.size()))) {
            changes.add(new ChangeView(change.entityType(), change.entityId(), change.revision(), change.op(),
                    change.data()));
            last = change.sequence();
        }
        jdbc.sql("insert into sync_device_cursor (device_id, workspace_id, last_sequence, pulled_at) "
                        + "values (?, ?, ?, ?) on conflict (device_id) do update "
                        + "set last_sequence = excluded.last_sequence, pulled_at = excluded.pulled_at")
                .params(device.deviceId(), workspaceId, last, Timestamp.from(now)).update();
        return new ChangePage(changes, CursorCodec.encode(workspaceId, last, now), hasMore);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    SnapshotPage snapshot(CurrentDevice device, String after, Integer limit) {
        UUID workspaceId = device.workspaceId();
        int pageSize = pageSize(limit);
        long head = store.headSequence(workspaceId);
        String afterType = "";
        UUID afterId = new UUID(Long.MIN_VALUE, Long.MIN_VALUE);
        if (after != null && !after.isBlank()) {
            int separator = after.indexOf(':');
            try {
                afterType = after.substring(0, separator);
                afterId = UUID.fromString(after.substring(separator + 1));
            } catch (RuntimeException e) {
                throw ApiException.badRequest("INVALID_REQUEST", "after must be an entity key from a snapshot.");
            }
        }
        List<SnapshotEntity> rows = jdbc.sql("select entity_type, entity_id, revision, data from sync_entity "
                        + "where workspace_id = ? and not deleted and (entity_type, entity_id) > (?, ?) "
                        + "order by entity_type, entity_id limit ?")
                .params(workspaceId, afterType, afterId, pageSize + 1)
                .query((rs, row) -> new SnapshotEntity(rs.getString("entity_type"),
                        rs.getObject("entity_id", UUID.class), rs.getLong("revision"),
                        JsonValues.parseObject(rs.getString("data"))))
                .list();
        boolean hasMore = rows.size() > pageSize;
        List<SnapshotEntity> page = rows.subList(0, Math.min(pageSize, rows.size()));
        String next = page.isEmpty() ? (after == null ? "" : after)
                : page.getLast().entityType() + ":" + page.getLast().entityId();
        return new SnapshotPage(List.copyOf(page), next, hasMore,
                CursorCodec.encode(workspaceId, head, clock.instant()));
    }

    /**
     * Whether a purge after the cursor was issued removed a delete the
     * client has not seen. A client that read the log only after the purge
     * never received the purged entities, so it is not affected.
     */
    private boolean missedPurge(UUID workspaceId, CursorCodec.Cursor cursor) {
        return jdbc.sql("select purged_through, purged_at from sync_purge_watermark where workspace_id = ?")
                .param(workspaceId)
                .query((rs, row) -> cursor.sequence() < rs.getLong("purged_through")
                        && cursor.issuedAt().isBefore(rs.getTimestamp("purged_at").toInstant()))
                .optional().orElse(false);
    }

    private int pageSize(Integer limit) {
        if (limit == null) {
            return properties.maxPageSize();
        }
        return Math.max(1, Math.min(limit, properties.maxPageSize()));
    }
}
