package com.paulsnow.finance.server.jobs;

import java.util.UUID;

import tools.jackson.databind.JsonNode;

/**
 * A claimed job handed to its {@link JobHandler}.
 *
 * @param id          stable job identifier
 * @param workspaceId owning workspace, or null for maintenance jobs
 * @param type        handler type
 * @param payload     handler input
 * @param attempt     1 for the first attempt
 * @author Paul Snow
 * @since 0.0.0
 */
public record Job(UUID id, UUID workspaceId, String type, JsonNode payload, int attempt) {
}
