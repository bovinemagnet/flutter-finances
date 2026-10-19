package com.paulsnow.finance.server.sync;

import java.util.List;

import com.fasterxml.jackson.annotation.JsonInclude;

import tools.jackson.databind.JsonNode;

/**
 * The outcome of one command.
 *
 * @param commandId the command's identifier as sent
 * @param status    {@code applied}, {@code previously_applied}, {@code conflict},
 *                  {@code validation_failed} or {@code permission_denied}
 * @param revision  canonical revision of the target entity when accepted
 * @param cursor    change feed position of the accepted change
 * @param errors    error codes, empty when none
 * @param conflict  server state on conflict
 * @author Paul Snow
 * @since 0.0.0
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record CommandResult(String commandId, String status, Long revision, String cursor,
        @JsonInclude(JsonInclude.Include.ALWAYS) List<String> errors, Conflict conflict) {

    public static final String APPLIED = "applied";
    public static final String PREVIOUSLY_APPLIED = "previously_applied";
    public static final String CONFLICT = "conflict";
    public static final String VALIDATION_FAILED = "validation_failed";
    public static final String PERMISSION_DENIED = "permission_denied";

    /**
     * Server state reported with a conflict.
     *
     * @param serverRevision current revision on the server
     * @param serverState    current entity, or null when deleted or absent
     * @param fields         fields changed on the server since the command's base revision
     */
    public record Conflict(long serverRevision, @JsonInclude(JsonInclude.Include.ALWAYS) JsonNode serverState,
            List<String> fields) {
    }

    public CommandResult {
        errors = errors == null ? List.of() : List.copyOf(errors);
    }

    /** Returns whether the command's change is part of canonical state. */
    public boolean accepted() {
        return APPLIED.equals(status) || PREVIOUSLY_APPLIED.equals(status);
    }

    static CommandResult rejected(String commandId, String status, List<String> errors) {
        return new CommandResult(commandId, status, null, null, errors, null);
    }

    CommandResult withStatus(String newStatus) {
        return new CommandResult(commandId, newStatus, revision, cursor, errors, conflict);
    }
}
