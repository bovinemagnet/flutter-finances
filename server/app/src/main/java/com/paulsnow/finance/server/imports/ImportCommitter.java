package com.paulsnow.finance.server.imports;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.core.ledger.Journal;
import com.paulsnow.finance.core.ledger.JournalStatus;
import com.paulsnow.finance.core.ledger.Posting;
import com.paulsnow.finance.core.ledger.TransactionType;
import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.server.ledger.JournalJson;
import com.paulsnow.finance.server.sync.CommandResult;
import com.paulsnow.finance.server.sync.EntityReader;
import com.paulsnow.finance.server.sync.SyncCommand;
import com.paulsnow.finance.server.sync.SyncCommandService;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Turns import rows into journals through the sync command path, so they
 * get the same validation, idempotency and change records as device
 * commands. Journal and command identifiers derive from the batch and row,
 * and the entry time is the batch's creation time, so running a commit
 * again (after a crash, or a repeated request) replays the same commands
 * and creates nothing twice (A12).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ImportCommitter {

    private static final int MAX_PAYEE = 500;

    private final ImportRepository repository;
    private final SyncCommandService commands;
    private final EntityReader entities;
    private final Clock clock;
    private final Counter commitFailures;

    ImportCommitter(ImportRepository repository, SyncCommandService commands, EntityReader entities, Clock clock,
            MeterRegistry meters) {
        this.repository = repository;
        this.commands = commands;
        this.entities = entities;
        this.clock = clock;
        this.commitFailures = failures(meters, "commit");
        failures(meters, "preview");
    }

    static Counter failures(MeterRegistry meters, String stage) {
        return Counter.builder("finance.imports.failures").description("Import rows or files that failed, by stage")
                .tag("stage", stage).register(meters);
    }

    /**
     * Commits every row of a batch that is new or already claimed, then
     * marks the batch committed.
     *
     * @param workspace workspace
     * @param batch     batch in status {@code committing}
     * @return the batch result
     */
    JsonNode commit(WorkspaceInfo workspace, ImportRepository.Batch batch) {
        for (ImportRepository.Row row : repository.rowsWithStatus(batch.id(), "new", "committed")) {
            UUID journalId = derived("import-journal", batch.id(), row.rowNumber());
            UUID commandId = derived("import-command", batch.id(), row.rowNumber());
            if ("new".equals(row.status())) {
                try {
                    repository.markCommitted(batch.id(), row.rowNumber(), journalId, commandId);
                } catch (DuplicateKeyException e) {
                    // The same statement line was committed by another batch.
                    repository.setRowStatus(batch.id(), row.rowNumber(), "duplicate", null);
                    continue;
                }
            }
            ObjectNode payload = JsonNodeFactory.instance.objectNode();
            payload.set("journal", JournalJson.toJson(journal(workspace, batch, row, journalId)));
            CommandResult result = commands.submitAsServer(workspace, new SyncCommand(commandId.toString(),
                    workspace.id().toString(), null, "journal.post", "journal", journalId.toString(), 0L, 1,
                    payload));
            if (!result.accepted()) {
                commitFailures.increment();
                String code = result.errors().isEmpty() ? result.status().toUpperCase(java.util.Locale.ROOT)
                        : result.errors().getFirst();
                repository.setRowStatus(batch.id(), row.rowNumber(), "error", code);
            }
        }
        JsonNode result = summarise(batch.id());
        repository.complete(batch.id(), "committed", result, clock.instant());
        return result;
    }

    /**
     * Reverses the journals a batch created, holding back any journal
     * edited or corrected since (IMP 02).
     *
     * @param workspace workspace
     * @param batch     committed batch
     * @return the rollback result
     */
    JsonNode rollback(WorkspaceInfo workspace, ImportRepository.Batch batch) {
        int reversed = 0;
        List<ObjectNode> held = new ArrayList<>();
        for (ImportRepository.Row row : repository.rowsWithStatus(batch.id(), "committed")) {
            var entity = entities.find(workspace.id(), row.journalId()).orElse(null);
            boolean untouched = entity != null && entity.isLive("journal") && entity.revision() == 1
                    && JournalStatus.POSTED.wire().equals(entity.data().path("status").asString());
            CommandResult result = null;
            if (untouched) {
                Journal original = JournalJson.parse(entity.data(), workspace.currency()).journal();
                ObjectNode payload = JsonNodeFactory.instance.objectNode();
                payload.put("originalId", original.id());
                payload.set("reversal", JournalJson.toJson(reversal(original, batch)));
                payload.putNull("replacement");
                result = commands.submitAsServer(workspace, new SyncCommand(
                        derived("import-rollback-command", row.journalId(), 0).toString(), workspace.id().toString(),
                        null, "journal.correct", "journal", original.id(), 1L, 1, payload));
            }
            if (result != null && result.accepted()) {
                repository.setRowStatus(batch.id(), row.rowNumber(), "rolled_back", null);
                reversed++;
            } else {
                ObjectNode item = JsonNodeFactory.instance.objectNode();
                item.put("rowNumber", row.rowNumber());
                item.put("journalId", row.journalId().toString());
                item.put("reason", result == null ? "EDITED_SINCE_IMPORT" : result.status().toUpperCase());
                held.add(item);
            }
        }
        ObjectNode result = batch.result() == null ? JsonNodeFactory.instance.objectNode()
                : (ObjectNode) batch.result().deepCopy();
        ObjectNode rollback = result.putObject("rollback");
        rollback.put("reversed", reversed);
        held.forEach(rollback.putArray("heldForReview")::add);
        repository.complete(batch.id(), "rolled_back", result, clock.instant());
        return result;
    }

    /** Counts rows by outcome. */
    JsonNode summarise(UUID batchId) {
        Map<String, Integer> counts = repository.statusCounts(batchId);
        ObjectNode result = JsonNodeFactory.instance.objectNode();
        result.put("imported", counts.getOrDefault("committed", 0));
        result.put("duplicates", counts.getOrDefault("duplicate", 0));
        result.put("skipped", counts.getOrDefault("skipped", 0));
        result.put("errors", counts.getOrDefault("error", 0));
        return result;
    }

    private static Journal journal(WorkspaceInfo workspace, ImportRepository.Batch batch, ImportRepository.Row row,
            UUID journalId) {
        long amount = row.amountMinor();
        long magnitude = Math.abs(amount);
        String account = batch.accountId();
        String code = workspace.currency().code();
        boolean outflow = amount < 0;
        List<Posting> postings = outflow
                ? List.of(new Posting(batch.outflowCategoryId(), magnitude, code), new Posting(account, -magnitude, code))
                : List.of(new Posting(account, magnitude, code), new Posting(batch.inflowCategoryId(), -magnitude, code));
        String payee = row.description().length() > MAX_PAYEE ? row.description().substring(0, MAX_PAYEE)
                : row.description();
        return new Journal(journalId.toString(), outflow ? TransactionType.EXPENSE : TransactionType.INCOME,
                JournalStatus.POSTED, row.date(), batch.createdAt(), workspace.currency(), postings, account, null,
                new Money(magnitude, workspace.currency()), payee, null, Set.of(), null, null, null);
    }

    private static Journal reversal(Journal original, ImportRepository.Batch batch) {
        return new Journal(derived("import-rollback", UUID.fromString(original.id()), 0).toString(),
                TransactionType.REVERSAL, JournalStatus.POSTED, original.effectiveDate(), batch.createdAt(),
                original.currency(), original.postings().stream().map(Posting::negated).toList(),
                original.accountId(), original.counterAccountId(), original.amount(), original.payee(), null,
                Set.of(), null, original.id(), null);
    }

    private static UUID derived(String purpose, UUID id, int row) {
        return UUID.nameUUIDFromBytes((purpose + ":" + id + ":" + row).getBytes(StandardCharsets.UTF_8));
    }
}
