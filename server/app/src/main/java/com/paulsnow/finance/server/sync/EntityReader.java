package com.paulsnow.finance.server.sync;

import java.util.LinkedHashSet;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Consumer;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import tools.jackson.databind.JsonNode;

/**
 * Read-only access to canonical entity state for other modules, always
 * scoped to one workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class EntityReader {

    /**
     * A live entity.
     *
     * @param entityType type
     * @param entityId   identifier
     * @param revision   current revision
     * @param data       current JSON
     */
    public record LiveEntity(String entityType, UUID entityId, long revision, JsonNode data) {
    }

    /**
     * An entity's current state.
     *
     * @param type     entity type
     * @param id       identifier
     * @param revision current revision
     * @param data     current JSON, null when deleted
     * @param deleted  whether it is a tombstone
     */
    public record EntityView(String type, UUID id, long revision, JsonNode data, boolean deleted) {

        /** Returns whether the entity exists, is of {@code entityType} and is not deleted. */
        public boolean isLive(String entityType) {
            return !deleted && type.equals(entityType);
        }
    }

    private final JdbcClient jdbc;
    private final EntityStore store;

    EntityReader(JdbcClient jdbc, EntityStore store) {
        this.jdbc = jdbc;
        this.store = store;
    }

    /**
     * Returns whether a live (not deleted) entity of {@code entityType}
     * exists in the workspace.
     *
     * @param workspaceId workspace
     * @param entityType  type
     * @param entityId    identifier
     * @return true when live
     */
    public boolean isLive(UUID workspaceId, String entityType, UUID entityId) {
        return jdbc.sql("select exists (select 1 from sync_entity where workspace_id = ? and entity_id = ? "
                        + "and entity_type = ? and not deleted)")
                .params(workspaceId, entityId, entityType).query(Boolean.class).single();
    }

    /**
     * Streams every live entity of a workspace ordered by type and
     * identifier.
     *
     * @param workspaceId workspace
     * @param consumer    receives each entity
     */
    public void forEachLive(UUID workspaceId, Consumer<LiveEntity> consumer) {
        jdbc.sql("select entity_type, entity_id, revision, data from sync_entity where workspace_id = ? "
                        + "and not deleted order by entity_type, entity_id")
                .param(workspaceId)
                .query(rs -> {
                    consumer.accept(new LiveEntity(rs.getString("entity_type"), rs.getObject("entity_id", UUID.class),
                            rs.getLong("revision"), JsonValues.parseObject(rs.getString("data"))));
                });
    }

    /**
     * Returns the workspace's change feed position, the revision an export
     * has accepted (DATA 03).
     *
     * @param workspaceId workspace
     * @return the latest change sequence
     */
    public long headSequence(UUID workspaceId) {
        return store.headSequence(workspaceId);
    }

    /**
     * Returns an entity of the workspace.
     *
     * @param workspaceId workspace
     * @param entityId    entity
     * @return the entity, or empty when the workspace has none with that identifier
     */
    public Optional<EntityView> find(UUID workspaceId, UUID entityId) {
        return jdbc.sql("select entity_type, entity_id, revision, data, deleted from sync_entity "
                        + "where workspace_id = ? and entity_id = ?")
                .params(workspaceId, entityId)
                .query((rs, row) -> new EntityView(rs.getString("entity_type"), rs.getObject("entity_id", UUID.class),
                        rs.getLong("revision"), JsonValues.parseObject(rs.getString("data")),
                        rs.getBoolean("deleted")))
                .optional();
    }

    /**
     * Returns the identifiers of every live entity of a type.
     *
     * @param workspaceId workspace
     * @param entityType  entity type
     * @return identifiers as strings
     */
    public Set<String> liveIds(UUID workspaceId, String entityType) {
        Set<String> ids = new LinkedHashSet<>();
        jdbc.sql("select entity_id from sync_entity where workspace_id = ? and entity_type = ? and not deleted")
                .params(workspaceId, entityType).query(UUID.class).list()
                .forEach(id -> ids.add(id.toString()));
        return ids;
    }
}
