package com.paulsnow.finance.server.sync;

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
}
