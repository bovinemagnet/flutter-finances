package com.paulsnow.finance.server.sync;

import java.sql.Timestamp;
import java.time.Clock;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.TransactionSystemException;
import org.springframework.transaction.support.TransactionTemplate;

import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Processes one command: envelope and permission checks, then a single
 * database transaction that takes the workspace's write lock, consults the
 * idempotency record, applies the handler and stores the result of an
 * applied command together with the domain change and change records
 * (SYNC 02).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class CommandProcessor {

    private static final Logger LOG = LoggerFactory.getLogger(CommandProcessor.class);

    private static final Pattern ENTITY_TYPE = Pattern.compile("[a-zA-Z][a-zA-Z0-9_.-]{0,63}");

    private final TransactionTemplate transactions;
    private final JdbcClient jdbc;
    private final EntityStore store;
    private final CommandHandlers handlers;
    private final SyncMetrics metrics;
    private final Clock clock;

    CommandProcessor(TransactionTemplate transactions, JdbcClient jdbc, EntityStore store, CommandHandlers handlers,
            SyncMetrics metrics, Clock clock) {
        this.transactions = transactions;
        this.jdbc = jdbc;
        this.store = store;
        this.handlers = handlers;
        this.metrics = metrics;
        this.clock = clock;
    }

    /**
     * Processes a command.
     *
     * @param workspace      workspace the caller acts on
     * @param originDeviceId the calling device, or null for server-originated commands
     * @param command        the command
     * @return its result
     */
    CommandResult process(WorkspaceInfo workspace, UUID originDeviceId, SyncCommand command) {
        CommandResult result = processUnmetered(workspace, originDeviceId, command);
        metrics.recordCommand(result.status());
        return result;
    }

    private CommandResult processUnmetered(WorkspaceInfo workspace, UUID originDeviceId, SyncCommand command) {
        String rawId = command.commandId();
        UUID commandId = uuid(rawId);
        UUID entityId = uuid(command.entityId());
        String type = command.type();
        if (commandId == null || entityId == null || type == null || !isKnownType(type)
                || command.entityType() == null || !ENTITY_TYPE.matcher(command.entityType()).matches()
                || command.baseRevision() == null || command.baseRevision() < 0
                || command.schemaVersion() == null) {
            return CommandResult.rejected(rawId, CommandResult.VALIDATION_FAILED, List.of("INVALID_COMMAND"));
        }
        if (!workspace.id().equals(uuid(command.workspaceId()))
                || (originDeviceId != null && !originDeviceId.equals(uuid(command.deviceId())))) {
            return CommandResult.rejected(rawId, CommandResult.PERMISSION_DENIED, List.of("NOT_PERMITTED"));
        }
        JsonNode payload = command.payload();
        if (payload == null || payload.isNull() || payload.isMissingNode()) {
            payload = JsonNodeFactory.instance.objectNode();
        }
        if (!payload.isObject()) {
            return CommandResult.rejected(rawId, CommandResult.VALIDATION_FAILED, List.of("INVALID_COMMAND"));
        }
        String hash = JsonValues.sha256(envelopeForHash(command, payload));
        Outcome.Context ctx = new Outcome.Context(workspace, commandId, originDeviceId, command.entityType(),
                entityId, command.baseRevision(), payload);
        try {
            return transactions.execute(status -> {
                store.lockWorkspace(workspace.id());
                Optional<StoredResult> stored = findStored(workspace.id(), commandId);
                if (stored.isPresent()) {
                    if (!stored.get().hash().equals(hash)) {
                        return CommandResult.rejected(rawId, CommandResult.VALIDATION_FAILED,
                                List.of("IDEMPOTENCY_KEY_REUSED"));
                    }
                    CommandResult original = stored.get().result();
                    return original.accepted() ? original.withStatus(CommandResult.PREVIOUSLY_APPLIED) : original;
                }
                Outcome outcome = command.schemaVersion() != 1 ? Outcome.invalid("UNSUPPORTED_SCHEMA_VERSION")
                        : dispatch(type, ctx);
                CommandResult result = toResult(rawId, workspace.id(), outcome);
                if (result.accepted()) {
                    // Only applied commands changed state, so only they are
                    // recorded; a rejected command is re-evaluated on retry,
                    // for example after the client rebases it.
                    store(workspace.id(), commandId, hash, result);
                } else {
                    status.setRollbackOnly();
                }
                return result;
            });
        } catch (DataIntegrityViolationException | TransactionSystemException e) {
            // A database constraint caught something the Java validation let
            // through; nothing was committed.
            LOG.warn("Command {} rejected by a database constraint", commandId);
            return CommandResult.rejected(rawId, CommandResult.VALIDATION_FAILED, List.of("LEDGER_CONSTRAINT"));
        }
    }

    private Outcome dispatch(String type, Outcome.Context ctx) {
        return switch (type) {
            case "journal.post" -> handlers.journalPost(ctx);
            case "journal.correct" -> handlers.journalCorrect(ctx);
            case "entity.upsert" -> handlers.upsert(ctx);
            case "entity.delete" -> handlers.delete(ctx);
            default -> Outcome.invalid("INVALID_COMMAND");
        };
    }

    private CommandResult toResult(String commandId, UUID workspaceId, Outcome outcome) {
        return switch (outcome) {
            case Outcome.Applied applied -> {
                long sequence = applied.sequence() > 0 ? applied.sequence() : store.headSequence(workspaceId);
                yield new CommandResult(commandId, CommandResult.APPLIED, applied.revision(),
                        CursorCodec.encode(workspaceId, sequence, clock.instant()), List.of(), null);
            }
            case Outcome.Conflict conflict -> new CommandResult(commandId, CommandResult.CONFLICT, null, null,
                    conflict.errors(), new CommandResult.Conflict(conflict.serverRevision(), conflict.serverState(),
                            conflict.fields()));
            case Outcome.Invalid invalid -> CommandResult.rejected(commandId, CommandResult.VALIDATION_FAILED,
                    invalid.errors());
        };
    }

    private record StoredResult(String hash, CommandResult result) {
    }

    private Optional<StoredResult> findStored(UUID workspaceId, UUID commandId) {
        return jdbc.sql("select payload_hash, result from sync_idempotency where workspace_id = ? and command_id = ?")
                .params(workspaceId, commandId)
                .query((rs, row) -> new StoredResult(rs.getString("payload_hash").trim(),
                        readResult(JsonValues.parseObject(rs.getString("result")))))
                .optional();
    }

    private void store(UUID workspaceId, UUID commandId, String hash, CommandResult result) {
        jdbc.sql("insert into sync_idempotency (workspace_id, command_id, payload_hash, status, result, created_at) "
                        + "values (?, ?, ?, ?, ?::jsonb, ?)")
                .params(workspaceId, commandId, hash, result.status(), JsonValues.write(writeResult(result)),
                        Timestamp.from(clock.instant()))
                .update();
    }

    private static ObjectNode writeResult(CommandResult result) {
        ObjectNode json = JsonNodeFactory.instance.objectNode();
        json.put("commandId", result.commandId());
        json.put("status", result.status());
        if (result.revision() != null) {
            json.put("revision", result.revision());
        }
        if (result.cursor() != null) {
            json.put("cursor", result.cursor());
        }
        result.errors().forEach(json.putArray("errors")::add);
        if (!json.has("errors")) {
            json.putArray("errors");
        }
        if (result.conflict() != null) {
            ObjectNode conflict = json.putObject("conflict");
            conflict.put("serverRevision", result.conflict().serverRevision());
            conflict.set("serverState", result.conflict().serverState());
            result.conflict().fields().forEach(conflict.putArray("fields")::add);
        }
        return json;
    }

    private static CommandResult readResult(JsonNode json) {
        List<String> errors = new java.util.ArrayList<>();
        json.path("errors").forEach(e -> errors.add(e.asString()));
        CommandResult.Conflict conflict = null;
        if (json.path("conflict").isObject()) {
            JsonNode node = json.path("conflict");
            List<String> fields = new java.util.ArrayList<>();
            node.path("fields").forEach(f -> fields.add(f.asString()));
            JsonNode state = node.path("serverState");
            conflict = new CommandResult.Conflict(node.path("serverRevision").asLong(),
                    state.isObject() ? state : null, fields);
        }
        return new CommandResult(json.path("commandId").asString(), json.path("status").asString(),
                json.has("revision") ? json.path("revision").asLong() : null,
                json.has("cursor") ? json.path("cursor").asString() : null, errors, conflict);
    }

    /**
     * What a command means: its type, target and payload. The base revision,
     * workspace and device are excluded because the client legitimately
     * rewrites them for unsent commands (rebase, bootstrap) while keeping
     * the commandId.
     */
    private static JsonNode envelopeForHash(SyncCommand command, JsonNode payload) {
        ObjectNode envelope = JsonNodeFactory.instance.objectNode();
        envelope.put("type", command.type());
        envelope.put("entityType", command.entityType());
        envelope.put("entityId", command.entityId().toLowerCase(java.util.Locale.ROOT));
        envelope.set("payload", payload);
        return envelope;
    }

    private static boolean isKnownType(String type) {
        return switch (type) {
            case "journal.post", "journal.correct", "entity.upsert", "entity.delete" -> true;
            default -> false;
        };
    }

    private static UUID uuid(String value) {
        if (value == null) {
            return null;
        }
        try {
            return UUID.fromString(value);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
