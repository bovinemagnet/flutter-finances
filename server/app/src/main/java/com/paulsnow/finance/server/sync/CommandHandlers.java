package com.paulsnow.finance.server.sync;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.server.ledger.JournalJson;
import com.paulsnow.finance.server.ledger.LedgerService;
import com.paulsnow.finance.server.sync.EntityStore.StoredEntity;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * Applies the four command types of the protocol. Each method runs inside
 * the command's transaction, after the idempotency check, and either writes
 * the domain change with its change records or changes nothing.
 * <p>
 * Competing money amounts, postings, statuses and deletions are never
 * resolved by last write wins: a stale base revision is a conflict.
 * Metadata fields merge when they do not conflict (SYNC 03).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class CommandHandlers {

    private static final String JOURNAL = "journal";

    private final EntityStore store;
    private final LedgerService ledger;

    CommandHandlers(EntityStore store, LedgerService ledger) {
        this.store = store;
        this.ledger = ledger;
    }

    /**
     * {@code journal.post} with payload {@code {"journal": Journal}}: create a
     * journal or replace a draft or pending one.
     */
    Outcome journalPost(Outcome.Context ctx) {
        if (!JOURNAL.equals(ctx.entityType())) {
            return Outcome.invalid("INVALID_ENTITY_TYPE");
        }
        JsonNode journalJson = ctx.payload().path("journal");
        JournalJson.Parsed parsed = JournalJson.parse(journalJson, ctx.workspace().currency());
        if (parsed.malformed()) {
            return rejected(List.of("INVALID_JOURNAL"));
        }
        Journal journal = parsed.journal();
        if (!journal.id().equals(ctx.entityId().toString())) {
            return Outcome.invalid("ENTITY_ID_MISMATCH");
        }
        Optional<StoredEntity> existing = store.lock(ctx.workspaceId(), ctx.entityId());
        if (existing.isPresent()) {
            StoredEntity entity = existing.get();
            Outcome blocked = blockedJournal(entity, ctx.baseRevision());
            if (blocked != null) {
                return blocked;
            }
        } else if (ctx.baseRevision() != 0) {
            return notFound();
        }
        List<String> errors = new ArrayList<>(validate(ctx, parsed));
        if (journal.type() == TransactionType.REVERSAL) {
            errors.add("INVALID_TYPE");
        }
        if (!errors.isEmpty()) {
            return rejected(errors);
        }
        ObjectNode data = ((ObjectNode) journalJson).deepCopy();
        data.put("id", journal.id());
        if (existing.isPresent()) {
            ledger.replace(ctx.workspaceId(), journal);
            long sequence = store.update(ctx.workspaceId(), existing.get(), data, ctx.commandId(), ctx.deviceId());
            return new Outcome.Applied(existing.get().revision() + 1, sequence);
        }
        ledger.insert(ctx.workspaceId(), journal);
        return new Outcome.Applied(1, store.create(ctx.workspaceId(), JOURNAL, ctx.entityId(), data,
                ctx.commandId(), ctx.deviceId()));
    }

    /** {@code journal.correct}: reverse a posted journal and optionally replace it, atomically. */
    Outcome journalCorrect(Outcome.Context ctx) {
        if (!JOURNAL.equals(ctx.entityType())) {
            return Outcome.invalid("INVALID_ENTITY_TYPE");
        }
        JsonNode payload = ctx.payload();
        if (!payload.path("originalId").isString() || !payload.path("reversal").isObject()) {
            return rejected(List.of("INVALID_JOURNAL"));
        }
        if (!payload.path("originalId").asString().equalsIgnoreCase(ctx.entityId().toString())) {
            return Outcome.invalid("ENTITY_ID_MISMATCH");
        }
        Optional<StoredEntity> found = store.lock(ctx.workspaceId(), ctx.entityId());
        if (found.isEmpty()) {
            return notFound();
        }
        StoredEntity originalEntity = found.get();
        if (originalEntity.deleted()) {
            return deleted(originalEntity);
        }
        if (!JOURNAL.equals(originalEntity.type())) {
            return Outcome.invalid("ENTITY_TYPE_MISMATCH");
        }
        if (ctx.baseRevision() != originalEntity.revision()) {
            return stale(originalEntity, ctx.baseRevision());
        }
        Journal original = JournalJson.parse(originalEntity.data(), ctx.workspace().currency()).journal();
        if (original.status() == JournalStatus.REVERSED) {
            return stale(originalEntity, ctx.baseRevision());
        }
        if (original.status() != JournalStatus.POSTED) {
            return rejected(List.of("INVALID_STATUS"));
        }

        Set<String> errors = new LinkedHashSet<>();
        JournalJson.Parsed reversalParsed = JournalJson.parse(payload.path("reversal"), ctx.workspace().currency());
        JsonNode replacementJson = payload.path("replacement");
        JournalJson.Parsed replacementParsed = replacementJson.isObject()
                ? JournalJson.parse(replacementJson, ctx.workspace().currency()) : null;
        if (reversalParsed.malformed() || (replacementParsed != null && replacementParsed.malformed())
                || !(replacementJson.isObject() || replacementJson.isNull() || replacementJson.isMissingNode())) {
            return rejected(List.of("INVALID_JOURNAL"));
        }
        Journal reversal = reversalParsed.journal();
        errors.addAll(validate(ctx, reversalParsed));
        if (reversal.type() != TransactionType.REVERSAL || reversal.status() != JournalStatus.POSTED
                || !ledger.isExactReversal(original, reversal)) {
            errors.add("REVERSAL_MISMATCH");
        }
        Journal replacement = replacementParsed == null ? null : replacementParsed.journal();
        Set<String> newIds = new TreeSet<>();
        newIds.add(reversal.id());
        if (replacement != null) {
            errors.addAll(validate(ctx, replacementParsed));
            if (replacement.type() == TransactionType.REVERSAL) {
                errors.add("INVALID_TYPE");
            }
            if (!original.id().equals(replacement.replaces())) {
                errors.add("REPLACEMENT_MISMATCH");
            }
            if (!newIds.add(replacement.id())) {
                errors.add("DUPLICATE_ENTITY");
            }
        }
        for (String id : newIds) {
            if (id.equals(original.id()) || store.exists(ctx.workspaceId(), UUID.fromString(id))) {
                errors.add("DUPLICATE_ENTITY");
            }
        }
        if (!errors.isEmpty()) {
            return rejected(List.copyOf(errors));
        }

        ledger.markReversed(ctx.workspaceId(), original.id());
        ledger.insert(ctx.workspaceId(), reversal);
        ObjectNode reversedData = originalEntity.data().deepCopy();
        reversedData.put("status", JournalStatus.REVERSED.wire());
        long sequence = store.update(ctx.workspaceId(), originalEntity, reversedData, ctx.commandId(),
                ctx.deviceId());
        sequence = store.create(ctx.workspaceId(), JOURNAL, UUID.fromString(reversal.id()),
                ((ObjectNode) payload.path("reversal")).deepCopy(), ctx.commandId(), ctx.deviceId());
        if (replacement != null) {
            ledger.insert(ctx.workspaceId(), replacement);
            sequence = store.create(ctx.workspaceId(), JOURNAL, UUID.fromString(replacement.id()),
                    ((ObjectNode) replacementJson).deepCopy(), ctx.commandId(), ctx.deviceId());
        }
        return new Outcome.Applied(originalEntity.revision() + 1, sequence);
    }

    /** {@code entity.upsert}: create an entity or merge changed fields. */
    Outcome upsert(Outcome.Context ctx) {
        JsonNode fieldsNode = ctx.payload().path("fields");
        if (!fieldsNode.isObject()) {
            return Outcome.invalid("INVALID_COMMAND");
        }
        ObjectNode fields = ((ObjectNode) fieldsNode).deepCopy();
        JsonNode id = fields.remove("id");
        if (id != null && !id.isNull() && !id.asString("").equalsIgnoreCase(ctx.entityId().toString())) {
            return Outcome.invalid("ENTITY_ID_MISMATCH");
        }
        if (JOURNAL.equals(ctx.entityType())) {
            // Journals change only through journal commands; their payee,
            // notes and tags are annotated through a separate entity.
            return Outcome.invalid("USE_JOURNAL_COMMANDS");
        }
        Optional<StoredEntity> existing = store.lock(ctx.workspaceId(), ctx.entityId());
        if (existing.isEmpty()) {
            if (ctx.baseRevision() != 0) {
                return notFound();
            }
            String error = EntityRules.check(ctx.entityType(), fields, null);
            if (error != null) {
                return Outcome.invalid(error);
            }
            ObjectNode data = fields.objectNode();
            data.put("id", ctx.entityId().toString());
            data.setAll(fields);
            return new Outcome.Applied(1, store.create(ctx.workspaceId(), ctx.entityType(), ctx.entityId(), data,
                    ctx.commandId(), ctx.deviceId()));
        }
        StoredEntity entity = existing.get();
        if (entity.deleted()) {
            return deleted(entity);
        }
        if (!entity.type().equals(ctx.entityType())) {
            return Outcome.invalid("ENTITY_TYPE_MISMATCH");
        }
        Set<String> conflicting = new TreeSet<>();
        for (Map.Entry<String, JsonNode> field : fields.properties()) {
            if (entity.fieldRevision(field.getKey()) > ctx.baseRevision()
                    && !JsonValues.same(entity.data().get(field.getKey()), field.getValue())) {
                conflicting.add(field.getKey());
            }
        }
        if (!conflicting.isEmpty()) {
            return new Outcome.Conflict(entity.revision(), entity.data(), List.copyOf(conflicting), List.of());
        }
        String error = EntityRules.check(ctx.entityType(), fields, entity.data());
        if (error != null) {
            return Outcome.invalid(error);
        }
        ObjectNode merged = entity.data().deepCopy();
        boolean changed = false;
        for (Map.Entry<String, JsonNode> field : fields.properties()) {
            if (!JsonValues.same(merged.get(field.getKey()), field.getValue())) {
                merged.set(field.getKey(), field.getValue());
                changed = true;
            }
        }
        if (!changed) {
            return new Outcome.Applied(entity.revision(), 0);
        }
        return new Outcome.Applied(entity.revision() + 1,
                store.update(ctx.workspaceId(), entity, merged, ctx.commandId(), ctx.deviceId()));
    }

    /** {@code entity.delete}: write a tombstone. Posted journals are never deleted. */
    Outcome delete(Outcome.Context ctx) {
        Optional<StoredEntity> existing = store.lock(ctx.workspaceId(), ctx.entityId());
        if (existing.isEmpty()) {
            return notFound();
        }
        StoredEntity entity = existing.get();
        if (entity.deleted()) {
            return deleted(entity);
        }
        if (!entity.type().equals(ctx.entityType())) {
            return Outcome.invalid("ENTITY_TYPE_MISMATCH");
        }
        boolean journal = JOURNAL.equals(entity.type());
        if (journal && isPostedLedger(entity)) {
            return rejected(List.of("POSTED_JOURNAL_IMMUTABLE"));
        }
        if (ctx.baseRevision() != entity.revision()) {
            return stale(entity, ctx.baseRevision());
        }
        if (("account".equals(entity.type()) || "category".equals(entity.type()))
                && ledger.isReferenced(ctx.workspaceId(), entity.id().toString())) {
            return Outcome.invalid("ENTITY_IN_USE");
        }
        if (journal) {
            ledger.deleteUnposted(ctx.workspaceId(), entity.id().toString());
        }
        return new Outcome.Applied(entity.revision() + 1,
                store.delete(ctx.workspaceId(), entity, ctx.commandId(), ctx.deviceId()));
    }

    private Outcome blockedJournal(StoredEntity entity, long baseRevision) {
        if (entity.deleted()) {
            return deleted(entity);
        }
        if (!JOURNAL.equals(entity.type())) {
            return Outcome.invalid("ENTITY_TYPE_MISMATCH");
        }
        if (isPostedLedger(entity)) {
            return rejected(List.of("POSTED_JOURNAL_IMMUTABLE"));
        }
        if (baseRevision != entity.revision()) {
            return stale(entity, baseRevision);
        }
        return null;
    }

    private List<String> validate(Outcome.Context ctx, JournalJson.Parsed parsed) {
        return ledger.validate(parsed, ids -> store.liveLedgerEntities(ctx.workspaceId(), ids));
    }

    private Outcome rejected(List<String> errors) {
        ledger.recordRejection(errors);
        return new Outcome.Invalid(errors);
    }

    private static boolean isPostedLedger(StoredEntity entity) {
        String status = entity.data().path("status").asString("");
        return JournalStatus.POSTED.wire().equals(status) || JournalStatus.REVERSED.wire().equals(status);
    }

    private static Outcome stale(StoredEntity entity, long baseRevision) {
        return new Outcome.Conflict(entity.revision(), entity.data(), entity.fieldsChangedSince(baseRevision),
                List.of());
    }

    private static Outcome deleted(StoredEntity entity) {
        return new Outcome.Conflict(entity.revision(), null, List.of(), List.of("ENTITY_DELETED"));
    }

    private static Outcome notFound() {
        return new Outcome.Conflict(0, null, List.of(), List.of("ENTITY_NOT_FOUND"));
    }
}
