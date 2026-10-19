package com.paulsnow.finance.server.sync;

import java.util.UUID;

/**
 * Published inside the transaction of an {@code entity.delete} command once
 * the tombstone is written, so other modules can remove data they derived
 * from the entity in the same transaction.
 *
 * @param workspaceId workspace
 * @param entityType  type of the deleted entity, for example {@code receipt}
 * @param entityId    identifier of the deleted entity
 * @author Paul Snow
 * @since 0.0.0
 */
public record EntityDeleted(UUID workspaceId, String entityType, UUID entityId) {
}
