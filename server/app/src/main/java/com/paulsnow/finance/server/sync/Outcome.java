package com.paulsnow.finance.server.sync;

import java.util.List;
import java.util.UUID;

import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import tools.jackson.databind.JsonNode;

/**
 * What a command handler decided.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
sealed interface Outcome {

    /**
     * The change was committed.
     *
     * @param revision resulting revision of the target entity
     * @param sequence last change sequence written, or 0 when nothing changed
     */
    record Applied(long revision, long sequence) implements Outcome {
    }

    /**
     * The command was based on stale state; nothing was applied.
     *
     * @param serverRevision current revision (0 when absent)
     * @param serverState    current entity JSON, or null
     * @param fields         conflicting fields
     * @param errors         extra codes such as {@code ENTITY_DELETED}
     */
    record Conflict(long serverRevision, JsonNode serverState, List<String> fields, List<String> errors)
            implements Outcome {
    }

    /**
     * The command broke a rule; nothing was applied.
     *
     * @param errors error codes
     */
    record Invalid(List<String> errors) implements Outcome {
    }

    /**
     * The caller may not make this change (a viewer, or an entity the
     * caller cannot see); nothing was applied.
     *
     * @param errors error codes
     */
    record Denied(List<String> errors) implements Outcome {
    }

    static Denied denied() {
        return new Denied(List.of("NOT_PERMITTED"));
    }

    static Invalid invalid(String... errors) {
        return new Invalid(List.of(errors));
    }

    /**
     * Everything a handler needs about one command.
     *
     * @param workspace    target workspace
     * @param commandId    idempotency key
     * @param deviceId     originating device, null for server-originated commands
     * @param entityType   entity type
     * @param entityId     target entity
     * @param baseRevision revision the device last saw
     * @param payload      payload object
     * @param userId       calling user, null for server-originated commands
     * @param visibility   what the calling user may see
     */
    record Context(WorkspaceInfo workspace, UUID commandId, UUID deviceId, String entityType, UUID entityId,
            long baseRevision, JsonNode payload, UUID userId, Visibility visibility) {

        UUID workspaceId() {
            return workspace.id();
        }
    }
}
