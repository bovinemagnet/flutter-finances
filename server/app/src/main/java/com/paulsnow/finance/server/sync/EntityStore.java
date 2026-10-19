package com.paulsnow.finance.server.sync;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Entity rows with per-field revisions, and the append-only change log.
 * Every write appends exactly one change record in the caller's
 * transaction.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Repository
class EntityStore {

    /**
     * A stored entity.
     *
     * @param id             entity identifier
     * @param type           entity type
     * @param revision       current revision
     * @param data           current JSON, null when deleted
     * @param fieldRevisions revision at which each top-level field last changed
     * @param deleted        whether it is a tombstone
     */
    record StoredEntity(UUID id, String type, long revision, ObjectNode data, ObjectNode fieldRevisions,
            boolean deleted) {

        long fieldRevision(String field) {
            return fieldRevisions.path(field).asLong(revision);
        }

        /** Fields changed on the server after {@code baseRevision}, sorted. */
        List<String> fieldsChangedSince(long baseRevision) {
            Set<String> fields = new TreeSet<>();
            fieldRevisions.properties().forEach(e -> {
                if (e.getValue().asLong() > baseRevision) {
                    fields.add(e.getKey());
                }
            });
            return List.copyOf(fields);
        }
    }

    /** A change log row. */
    record Change(long sequence, String entityType, UUID entityId, long revision, String op, JsonNode data) {
    }

    private final JdbcClient jdbc;
    private final Clock clock;

    EntityStore(JdbcClient jdbc, Clock clock) {
        this.jdbc = jdbc;
        this.clock = clock;
    }

    /** Serialises writers of one workspace so change sequences commit in order. */
    void lockWorkspace(UUID workspaceId) {
        long key = workspaceId.getMostSignificantBits() ^ workspaceId.getLeastSignificantBits();
        jdbc.sql("select pg_advisory_xact_lock(?)").param(key).query((RowCallbackHandler) rs -> {
        });
    }

    Optional<StoredEntity> lock(UUID workspaceId, UUID entityId) {
        return jdbc.sql("select entity_id, entity_type, revision, data, field_revisions, deleted from sync_entity "
                        + "where workspace_id = ? and entity_id = ? for update")
                .params(workspaceId, entityId)
                .query(EntityStore::mapEntity)
                .optional();
    }

    boolean exists(UUID workspaceId, UUID entityId) {
        return jdbc.sql("select exists (select 1 from sync_entity where workspace_id = ? and entity_id = ?)")
                .params(workspaceId, entityId).query(Boolean.class).single();
    }

    /** Returns which of {@code ids} are live account or category entities. */
    Set<String> liveLedgerEntities(UUID workspaceId, Collection<String> ids) {
        List<UUID> uuids = new ArrayList<>();
        for (String id : ids) {
            try {
                uuids.add(UUID.fromString(id));
            } catch (IllegalArgumentException e) {
                // Not an entity identifier, so never live.
            }
        }
        if (uuids.isEmpty()) {
            return Set.of();
        }
        Set<String> live = new HashSet<>();
        jdbc.sql("select entity_id from sync_entity where workspace_id = ? and entity_id = any(?) "
                        + "and entity_type in ('account', 'category') and not deleted")
                .params(workspaceId, uuids.toArray(UUID[]::new))
                .query(UUID.class).list()
                .forEach(id -> live.add(id.toString()));
        Set<String> result = new LinkedHashSet<>();
        for (String id : ids) {
            try {
                if (live.contains(UUID.fromString(id).toString())) {
                    result.add(id);
                }
            } catch (IllegalArgumentException e) {
                // Skip.
            }
        }
        return result;
    }

    /** Creates an entity at revision 1 and appends its change. */
    long create(UUID workspaceId, String type, UUID entityId, ObjectNode data, UUID commandId, UUID deviceId) {
        ObjectNode revisions = FieldRevisionsSupport.initial(data, 1);
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("insert into sync_entity (workspace_id, entity_id, entity_type, revision, data, field_revisions, "
                        + "created_at, updated_at) values (?, ?, ?, 1, ?::jsonb, ?::jsonb, ?, ?)")
                .params(workspaceId, entityId, type, JsonValues.write(data), JsonValues.write(revisions), now, now)
                .update();
        return append(workspaceId, type, entityId, 1, "upsert", data, commandId, deviceId);
    }

    /** Stores a new version of an entity and appends its change. */
    long update(UUID workspaceId, StoredEntity entity, ObjectNode data, UUID commandId, UUID deviceId) {
        long revision = entity.revision() + 1;
        ObjectNode revisions = FieldRevisionsSupport.next(entity.data(), data, entity.fieldRevisions(), revision);
        jdbc.sql("update sync_entity set revision = ?, data = ?::jsonb, field_revisions = ?::jsonb, updated_at = ? "
                        + "where workspace_id = ? and entity_id = ?")
                .params(revision, JsonValues.write(data), JsonValues.write(revisions),
                        Timestamp.from(clock.instant()), workspaceId, entity.id())
                .update();
        return append(workspaceId, entity.type(), entity.id(), revision, "upsert", data, commandId, deviceId);
    }

    /** Turns an entity into a tombstone and appends a delete change. */
    long delete(UUID workspaceId, StoredEntity entity, UUID commandId, UUID deviceId) {
        long revision = entity.revision() + 1;
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("update sync_entity set revision = ?, deleted = true, deleted_at = ?, updated_at = ? "
                        + "where workspace_id = ? and entity_id = ?")
                .params(revision, now, now, workspaceId, entity.id())
                .update();
        ObjectNode tombstone = JsonNodeFactory.instance.objectNode().put("id", entity.id().toString());
        return append(workspaceId, entity.type(), entity.id(), revision, "delete", tombstone, commandId, deviceId);
    }

    /**
     * The workspace's latest change position. Purged delete records still
     * count, so a cursor issued now is never before the purge watermark.
     */
    long headSequence(UUID workspaceId) {
        return jdbc.sql("select greatest((select coalesce(max(sequence), 0) from sync_change where workspace_id = ?), "
                        + "(select coalesce(max(purged_through), 0) from sync_purge_watermark where workspace_id = ?))")
                .params(workspaceId, workspaceId).query(Long.class).single();
    }

    List<Change> changesAfter(UUID workspaceId, long sequence, int limit) {
        return jdbc.sql("select sequence, entity_type, entity_id, revision, op, data from sync_change "
                        + "where workspace_id = ? and sequence > ? order by sequence limit ?")
                .params(workspaceId, sequence, limit)
                .query((rs, row) -> new Change(rs.getLong("sequence"), rs.getString("entity_type"),
                        rs.getObject("entity_id", UUID.class), rs.getLong("revision"), rs.getString("op"),
                        JsonValues.parseObject(rs.getString("data"))))
                .list();
    }

    private long append(UUID workspaceId, String type, UUID entityId, long revision, String op, JsonNode data,
            UUID commandId, UUID deviceId) {
        return jdbc.sql("insert into sync_change (workspace_id, entity_type, entity_id, revision, op, data, "
                        + "command_id, device_id, created_at) values (?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?) "
                        + "returning sequence")
                .params(workspaceId, type, entityId, revision, op, JsonValues.write(data), commandId, deviceId,
                        Timestamp.from(clock.instant()))
                .query(Long.class).single();
    }

    private static StoredEntity mapEntity(ResultSet rs, int row) throws SQLException {
        ObjectNode data = JsonValues.parseObject(rs.getString("data"));
        ObjectNode revisions = JsonValues.parseObject(rs.getString("field_revisions"));
        return new StoredEntity(rs.getObject("entity_id", UUID.class), rs.getString("entity_type"),
                rs.getLong("revision"), data,
                revisions == null ? JsonNodeFactory.instance.objectNode() : revisions, rs.getBoolean("deleted"));
    }
}
