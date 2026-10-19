package com.paulsnow.finance.server.imports;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.core.imports.CsvMapping;
import com.paulsnow.finance.core.imports.CsvParseResult;
import com.paulsnow.finance.core.imports.CsvStatementParser;
import com.paulsnow.finance.core.imports.Fingerprints;
import com.paulsnow.finance.core.imports.ImportErrorCode;
import com.paulsnow.finance.core.imports.ImportRow;
import com.paulsnow.finance.core.imports.ImportRowError;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.imports.ImportViews.BatchView;
import com.paulsnow.finance.server.imports.ImportViews.DateGap;
import com.paulsnow.finance.server.imports.ImportViews.MatchView;
import com.paulsnow.finance.server.imports.ImportViews.RowView;
import com.paulsnow.finance.server.imports.ImportViews.Totals;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.ledger.LedgerService;
import com.paulsnow.finance.server.ledger.LedgerService.PostingMovement;
import com.paulsnow.finance.server.sync.EntityLookup;
import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.WorkspaceInfo;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * CSV import preview, commit and rollback (IMP 01-03).
 * <p>
 * A batch is identified by workspace, account, file hash and settings hash,
 * so previewing the same file again returns the same batch. Each parsed row
 * gets the shared {@code csv.fingerprint}; a row whose fingerprint is
 * already committed (an overlapping statement) is a {@code duplicate} and
 * is skipped unless the user decides to import it. Matches with existing
 * entries and possible transfers are proposals only; nothing is invented to
 * make a statement balance.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class ImportService {

    /** Days either side of a row's date searched for match candidates. */
    static final int MATCH_WINDOW_DAYS = 3;

    private static final int MAX_MATCHES = 5;

    private final ImportRepository repository;
    private final ImportCommitter committer;
    private final EntityLookup entities;
    private final LedgerService ledger;
    private final JobService jobs;
    private final ImportProperties properties;
    private final TransactionTemplate transactions;
    private final JsonMapper json;
    private final Clock clock;
    private final Counter previewFailures;

    ImportService(ImportRepository repository, ImportCommitter committer, EntityLookup entities, LedgerService ledger,
            JobService jobs, ImportProperties properties, TransactionTemplate transactions, JsonMapper json,
            Clock clock, MeterRegistry meters) {
        this.repository = repository;
        this.committer = committer;
        this.entities = entities;
        this.ledger = ledger;
        this.jobs = jobs;
        this.properties = properties;
        this.transactions = transactions;
        this.json = json;
        this.clock = clock;
        this.previewFailures = ImportCommitter.failures(meters, "preview");
    }

    BatchView preview(CurrentMember member, ImportViews.PreviewRequest request) {
        WorkspaceInfo workspace = member.workspace();
        CsvMapping mapping = mapping(request, workspace);
        String accountId = mapping.accountId();
        requireLive(workspace.id(), accountId, "account", null, "UNKNOWN_ACCOUNT");
        requireLive(workspace.id(), request.outflowCategoryId(), "category", "expense", "UNKNOWN_CATEGORY");
        requireLive(workspace.id(), request.inflowCategoryId(), "category", "income", "UNKNOWN_CATEGORY");
        byte[] bytes = decodeBase64(request.contentBase64());
        String text;
        try {
            text = mapping.encoding().decode(bytes);
        } catch (IllegalArgumentException e) {
            throw fail(ApiException.badRequest("INVALID_ENCODING", "The file is not valid "
                    + mapping.encoding().wire() + " text; choose a different encoding."));
        }
        ObjectNode settings = JsonNodeFactory.instance.objectNode();
        settings.set("csv", json.valueToTree(mapping.toMap()));
        settings.put("outflowCategoryId", request.outflowCategoryId());
        settings.put("inflowCategoryId", request.inflowCategoryId());
        String fileHash = sha256(bytes);
        String settingsHash = sha256(json.writeValueAsString(settings).getBytes(StandardCharsets.UTF_8));
        Optional<ImportRepository.Batch> existing = repository.findByIdentity(workspace.id(), accountId, fileHash,
                settingsHash);
        if (existing.isPresent()) {
            return view(existing.get(), 0, properties.previewRows());
        }

        CsvParseResult parsed = CsvStatementParser.parse(text, mapping, workspace.currency().exponent());
        if (parsed.errors().stream().anyMatch(e -> e.code() == ImportErrorCode.COLUMN_NOT_FOUND)) {
            throw fail(ApiException.badRequest("COLUMN_NOT_FOUND", "A mapped column is not in the file's header."));
        }
        int records = parsed.rows().size() + parsed.errors().size();
        if (records > properties.maxRows()) {
            throw fail(ApiException.badRequest("TOO_MANY_ROWS",
                    "Import at most " + properties.maxRows() + " rows per file."));
        }
        List<String> fingerprints = Fingerprints.assign(accountId, parsed.rows());
        List<String> hashes = fingerprints.stream().map(f -> sha256(f.getBytes(StandardCharsets.UTF_8))).toList();
        Set<String> committed = repository.committedFingerprints(workspace.id(), hashes);
        Matcher matcher = matcher(workspace.id(), accountId, parsed.rows());

        List<ImportRepository.NewRow> rows = new ArrayList<>();
        long inflow = 0;
        long outflow = 0;
        int duplicates = 0;
        LocalDate first = null;
        LocalDate last = null;
        for (int i = 0; i < parsed.rows().size(); i++) {
            ImportRow row = parsed.rows().get(i);
            String fingerprint = fingerprints.get(i);
            boolean duplicate = committed.contains(hashes.get(i));
            duplicates += duplicate ? 1 : 0;
            if (row.amountMinor() > 0) {
                inflow += row.amountMinor();
            } else {
                outflow -= row.amountMinor();
            }
            first = first == null || row.date().isBefore(first) ? row.date() : first;
            last = last == null || row.date().isAfter(last) ? row.date() : last;
            rows.add(new ImportRepository.NewRow(row.rowNumber(), row.rawText(),
                    sha256(row.rawText().getBytes(StandardCharsets.UTF_8)), duplicate ? "duplicate" : "new", null,
                    row.date(), row.amountMinor(), row.description(), row.reference(), fingerprint, hashes.get(i),
                    Integer.parseInt(fingerprint.substring(fingerprint.lastIndexOf('#') + 1)),
                    matcher.matches(row)));
        }
        for (ImportRowError error : parsed.errors()) {
            String raw = error.rawText() == null ? "" : error.rawText();
            rows.add(new ImportRepository.NewRow(error.row(), raw, sha256(raw.getBytes(StandardCharsets.UTF_8)),
                    "error", error.code().code(), null, null, null, null, null, null, null, null));
        }
        rows.sort((a, b) -> Integer.compare(a.rowNumber(), b.rowNumber()));
        if (!parsed.errors().isEmpty()) {
            previewFailures.increment(parsed.errors().size());
        }

        ObjectNode summary = JsonNodeFactory.instance.objectNode();
        summary.put("inflowMinor", inflow);
        summary.put("outflowMinor", outflow);
        summary.put("netMinor", inflow - outflow);
        summary.put("firstDate", first == null ? null : first.toString());
        summary.put("lastDate", last == null ? null : last.toString());
        LocalDate previous = repository.lastCommittedDate(workspace.id(), accountId).orElse(null);
        if (previous != null && first != null && first.isAfter(previous.plusDays(1))) {
            ObjectNode gap = summary.putObject("dateGap");
            gap.put("from", previous.plusDays(1).toString());
            gap.put("to", first.minusDays(1).toString());
        }

        UUID batchId = Ids.newUuid();
        int errorCount = parsed.errors().size();
        String fileName = request.fileName() == null ? null
                : request.fileName().substring(0, Math.min(255, request.fileName().length()));
        Boolean inserted = transactions.execute(status -> {
            if (!repository.insertBatch(batchId, workspace.id(), accountId, fileHash, settingsHash, fileName,
                    settings, records, errorCount, summary, clock.instant())) {
                return false;
            }
            repository.insertRows(batchId, workspace.id(), rows);
            return true;
        });
        ImportRepository.Batch batch = Boolean.TRUE.equals(inserted)
                ? repository.find(workspace.id(), batchId).orElseThrow()
                : repository.findByIdentity(workspace.id(), accountId, fileHash, settingsHash).orElseThrow();
        return view(batch, 0, properties.previewRows());
    }

    /** Result of a commit request: the batch, and whether it continues as a job. */
    record CommitOutcome(BatchView batch, boolean accepted) {
    }

    CommitOutcome commit(CurrentMember member, UUID batchId, Map<String, String> decisions) {
        WorkspaceInfo workspace = member.workspace();
        ImportRepository.Batch batch = find(workspace.id(), batchId);
        switch (batch.status()) {
            case "committed" -> {
                return new CommitOutcome(view(batch, 0, properties.previewRows()), false);
            }
            case "rolled_back" -> throw ApiException.conflict("IMPORT_ROLLED_BACK", "This import was rolled back.");
            case "committing" -> {
                if (batch.jobId() != null) {
                    return new CommitOutcome(view(batch, 0, properties.previewRows()), true);
                }
            }
            default -> applyDecisions(batch, decisions == null ? Map.of() : decisions);
        }
        int pending = repository.rowsWithStatus(batch.id(), "new", "committed").size();
        if (pending > properties.synchronousRowLimit()) {
            transactions.executeWithoutResult(status -> {
                ObjectNode payload = JsonNodeFactory.instance.objectNode().put("batchId", batch.id().toString());
                UUID jobId = jobs.enqueue(ImportCommitJobHandler.TYPE, workspace.id(), payload);
                repository.setStatus(batch.id(), "committing", jobId);
            });
            return new CommitOutcome(view(find(workspace.id(), batchId), 0, properties.previewRows()), true);
        }
        repository.setStatus(batch.id(), "committing", null);
        committer.commit(workspace, find(workspace.id(), batchId));
        return new CommitOutcome(view(find(workspace.id(), batchId), 0, properties.previewRows()), false);
    }

    BatchView rollback(CurrentMember member, UUID batchId) {
        WorkspaceInfo workspace = member.workspace();
        ImportRepository.Batch batch = find(workspace.id(), batchId);
        if ("committed".equals(batch.status())) {
            committer.rollback(workspace, batch);
        } else if (!"rolled_back".equals(batch.status())) {
            throw ApiException.conflict("IMPORT_NOT_COMMITTED", "Only a committed import can be rolled back.");
        }
        return view(find(workspace.id(), batchId), 0, properties.previewRows());
    }

    BatchView get(CurrentMember member, UUID batchId, Integer offset, Integer limit) {
        int from = offset == null ? 0 : Math.max(0, offset);
        int size = limit == null ? properties.previewRows() : Math.max(1, Math.min(limit, 1000));
        return view(find(member.workspaceId(), batchId), from, size);
    }

    private void applyDecisions(ImportRepository.Batch batch, Map<String, String> decisions) {
        Map<Integer, ImportRepository.Row> rows = new HashMap<>();
        repository.rowsWithStatus(batch.id(), "new", "duplicate").forEach(r -> rows.put(r.rowNumber(), r));
        transactions.executeWithoutResult(status -> decisions.forEach((key, decision) -> {
            ImportRepository.Row row;
            try {
                row = rows.get(Integer.parseInt(key));
            } catch (NumberFormatException e) {
                throw ApiException.badRequest("INVALID_DECISION", "Decisions are keyed by row number.");
            }
            if (row == null) {
                return;
            }
            switch (decision) {
                case "skip" -> repository.setRowStatus(batch.id(), row.rowNumber(), "skipped", null);
                case "import" -> {
                    if ("duplicate".equals(row.status())) {
                        // A deliberate second copy gets its own fingerprint claim.
                        repository.forceRow(batch.id(), row.rowNumber(), sha256((row.fingerprintText() + "|forced|"
                                + batch.id() + "|" + row.rowNumber()).getBytes(StandardCharsets.UTF_8)));
                    }
                }
                default -> throw ApiException.badRequest("INVALID_DECISION", "Use import or skip.");
            }
        }));
    }

    BatchView view(ImportRepository.Batch batch, int offset, int limit) {
        Map<String, Integer> counts = repository.statusCounts(batch.id());
        List<RowView> rows = new ArrayList<>();
        for (ImportRepository.Row row : repository.rows(batch.id(), offset, limit)) {
            List<MatchView> matches = new ArrayList<>();
            if (row.matches() != null) {
                for (JsonNode match : row.matches()) {
                    matches.add(new MatchView(match.path("kind").asString(),
                            UUID.fromString(match.path("journalId").asString()),
                            LocalDate.parse(match.path("date").asString())));
                }
            }
            rows.add(new RowView(row.rowNumber(), row.date(), row.description(), row.amountMinor(), row.status(),
                    row.errorCode(), row.fingerprintText(), row.journalId(), row.matches() == null ? null : matches));
        }
        JsonNode summary = batch.summary();
        JsonNode gap = summary.path("dateGap");
        return new BatchView(batch.id(), batch.status(), batch.accountId(), batch.fileName(), batch.rowCount(),
                batch.errorCount(), counts.getOrDefault("new", 0), counts.getOrDefault("duplicate", 0),
                new Totals(summary.path("inflowMinor").asLong(), summary.path("outflowMinor").asLong(),
                        summary.path("netMinor").asLong()),
                date(summary.path("firstDate")), date(summary.path("lastDate")),
                gap.isObject() ? new DateGap(date(gap.path("from")), date(gap.path("to"))) : null, batch.result(),
                batch.jobId(), offset, rows);
    }

    private ImportRepository.Batch find(UUID workspaceId, UUID batchId) {
        return repository.find(workspaceId, batchId)
                .orElseThrow(() -> ApiException.notFound("IMPORT_NOT_FOUND", "Import not found."));
    }

    private CsvMapping mapping(ImportViews.PreviewRequest request, WorkspaceInfo workspace) {
        if (request.mapping() == null || !request.mapping().isObject()) {
            throw fail(ApiException.badRequest("INVALID_MAPPING", "Send the CSV mapping."));
        }
        CsvMapping mapping;
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> values = json.convertValue(request.mapping(), Map.class);
            mapping = CsvMapping.fromMap(values);
        } catch (RuntimeException e) {
            throw fail(ApiException.badRequest("INVALID_MAPPING", "The CSV mapping is not valid."));
        }
        if (!mapping.currencyCode().equals(workspace.currency().code())) {
            throw fail(ApiException.badRequest("CURRENCY_MISMATCH", "The statement is not in the workspace currency."));
        }
        return mapping;
    }

    private void requireLive(UUID workspaceId, String id, String type, String kind, String code) {
        UUID uuid;
        try {
            uuid = UUID.fromString(id);
        } catch (RuntimeException e) {
            throw fail(ApiException.badRequest(code, "Unknown " + type + "."));
        }
        EntityLookup.EntityView entity = entities.find(workspaceId, uuid).filter(e -> e.isLive(type))
                .orElseThrow(() -> fail(ApiException.badRequest(code, "Unknown " + type + ".")));
        if (kind != null && !kind.equals(entity.data().path("kind").asString())) {
            throw fail(ApiException.badRequest("WRONG_CATEGORY_KIND", "Use an " + kind + " category."));
        }
    }

    private byte[] decodeBase64(String content) {
        try {
            return java.util.Base64.getDecoder().decode(content == null ? "" : content);
        } catch (IllegalArgumentException e) {
            throw fail(ApiException.badRequest("INVALID_FILE", "contentBase64 is not valid Base64."));
        }
    }

    private ApiException fail(ApiException e) {
        previewFailures.increment();
        return e;
    }

    /** Finds existing entries and possible transfers near each row. */
    private final class Matcher {
        private final String accountId;
        private final Set<String> accounts;
        private final Map<Long, List<PostingMovement>> byAmount = new HashMap<>();

        private Matcher(String accountId, Set<String> accounts, List<PostingMovement> movements) {
            this.accountId = accountId;
            this.accounts = accounts;
            for (PostingMovement movement : movements) {
                byAmount.computeIfAbsent(movement.netMinor(), k -> new ArrayList<>()).add(movement);
            }
        }

        ArrayNode matches(ImportRow row) {
            ArrayNode found = JsonNodeFactory.instance.arrayNode();
            List<PostingMovement> candidates = new ArrayList<>(byAmount.getOrDefault(row.amountMinor(), List.of()));
            candidates.addAll(byAmount.getOrDefault(-row.amountMinor(), List.of()));
            candidates.sort((a, b) -> a.effectiveDate().compareTo(b.effectiveDate()));
            for (PostingMovement movement : candidates) {
                if (found.size() >= MAX_MATCHES) {
                    break;
                }
                if (Math.abs(ChronoUnit.DAYS.between(movement.effectiveDate(), row.date())) > MATCH_WINDOW_DAYS) {
                    continue;
                }
                String kind = null;
                if (movement.account().equals(accountId) && movement.netMinor() == row.amountMinor()) {
                    kind = "existingEntry";
                } else if (!movement.account().equals(accountId) && accounts.contains(movement.account())
                        && movement.netMinor() == -row.amountMinor()) {
                    kind = "transfer";
                }
                if (kind != null) {
                    found.addObject().put("kind", kind).put("journalId", movement.journalId().toString())
                            .put("date", movement.effectiveDate().toString());
                }
            }
            return found;
        }
    }

    private Matcher matcher(UUID workspaceId, String accountId, List<ImportRow> rows) {
        if (rows.isEmpty()) {
            return new Matcher(accountId, Set.of(), List.of());
        }
        LocalDate from = rows.stream().map(ImportRow::date).min(LocalDate::compareTo).orElseThrow();
        LocalDate to = rows.stream().map(ImportRow::date).max(LocalDate::compareTo).orElseThrow();
        return new Matcher(accountId, entities.liveIds(workspaceId, "account"),
                ledger.movementsBetween(workspaceId, from.minusDays(MATCH_WINDOW_DAYS), to.plusDays(MATCH_WINDOW_DAYS)));
    }

    private static LocalDate date(JsonNode node) {
        return node.isString() ? LocalDate.parse(node.asString()) : null;
    }

    static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
