package com.paulsnow.finance.server.sync;

import tools.jackson.databind.JsonNode;

/**
 * A versioned command envelope. Fields are read leniently so that one
 * malformed command fails on its own instead of failing the whole batch.
 *
 * @param commandId     idempotency key (UUID)
 * @param workspaceId   workspace the command belongs to
 * @param deviceId      device that created the command
 * @param type          {@code journal.post}, {@code journal.correct}, {@code entity.upsert} or {@code entity.delete}
 * @param entityType    entity type, for example {@code journal} or {@code account}
 * @param entityId      target entity (UUID)
 * @param baseRevision  revision the device last saw, 0 for a new entity
 * @param schemaVersion command schema version, currently 1
 * @param payload       type-specific payload
 * @author Paul Snow
 * @since 0.0.0
 */
public record SyncCommand(String commandId, String workspaceId, String deviceId, String type, String entityType,
        String entityId, Long baseRevision, Integer schemaVersion, JsonNode payload) {
}
