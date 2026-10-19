package com.paulsnow.finance.server.imports;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * SQL for import batches and their raw rows.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Repository
class ImportRepository {

    /** A stored batch. */
    record Batch(UUID id, UUID workspaceId, String accountId, String fileName, JsonNode settings, String status,
            int rowCount, int errorCount, JsonNode summary, JsonNode result, UUID jobId, Instant createdAt,
            Instant committedAt) {

        String outflowCategoryId() {
            return settings.path("outflowCategoryId").asString();
        }

        String inflowCategoryId() {
            return settings.path("inflowCategoryId").asString();
        }
    }

    /** A stored row. */
    record Row(int rowNumber, String raw, String status, String errorCode, LocalDate date, Long amountMinor,
            String description, String reference, String fingerprintText, String fingerprintHash, UUID journalId,
            UUID commandId, JsonNode matches) {
    }

    /** A row to insert. */
    record NewRow(int rowNumber, String raw, String rawHash, String status, String errorCode, LocalDate date,
            Long amountMinor, String description, String reference, String fingerprintText, String fingerprintHash,
            Integer occurrence, JsonNode matches) {
    }

    private final JdbcClient jdbc;
    private final JsonMapper json;

    ImportRepository(JdbcClient jdbc, JsonMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    Optional<Batch> find(UUID workspaceId, UUID batchId) {
        return jdbc.sql("select * from import_batch where id = ? and workspace_id = ?").params(batchId, workspaceId)
                .query(this::mapBatch).optional();
    }

    Optional<Batch> findByIdentity(UUID workspaceId, String accountId, String fileHash, String settingsHash) {
        return jdbc.sql("select * from import_batch where workspace_id = ? and account_id = ? and file_sha256 = ? "
                        + "and mapping_sha256 = ?")
                .params(workspaceId, accountId, fileHash, settingsHash).query(this::mapBatch).optional();
    }

    /** Inserts a batch unless an identical one exists; returns whether it was inserted. */
    boolean insertBatch(UUID id, UUID workspaceId, String accountId, String fileHash, String settingsHash,
            String fileName, JsonNode settings, int rowCount, int errorCount, JsonNode summary, Instant now) {
        return jdbc.sql("insert into import_batch (id, workspace_id, account_id, file_sha256, mapping_sha256, "
                        + "file_name, mapping, status, row_count, error_count, summary, created_at) "
                        + "values (?, ?, ?, ?, ?, ?, ?::jsonb, 'previewed', ?, ?, ?::jsonb, ?) "
                        + "on conflict (workspace_id, account_id, file_sha256, mapping_sha256) do nothing")
                .params(id, workspaceId, accountId, fileHash, settingsHash, fileName, json.writeValueAsString(settings),
                        rowCount, errorCount, json.writeValueAsString(summary), Timestamp.from(now))
                .update() == 1;
    }

    void insertRows(UUID batchId, UUID workspaceId, List<NewRow> rows) {
        for (NewRow row : rows) {
            jdbc.sql("insert into import_row (batch_id, row_number, workspace_id, raw, raw_sha256, status, "
                            + "error_code, effective_date, amount_minor, description, reference, fingerprint, "
                            + "occurrence, dedupe_key, matches) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, "
                            + "?::jsonb)")
                    .params(batchId, row.rowNumber(), workspaceId, row.raw(), row.rawHash(), row.status(),
                            row.errorCode(), row.date(), row.amountMinor(), row.description(), row.reference(),
                            row.fingerprintHash(), row.occurrence(), row.fingerprintText(),
                            row.matches() == null ? null : json.writeValueAsString(row.matches()))
                    .update();
        }
    }

    List<Row> rows(UUID batchId, int offset, int limit) {
        return jdbc.sql("select * from import_row where batch_id = ? order by row_number offset ? limit ?")
                .params(batchId, offset, limit).query(this::mapRow).list();
    }

    List<Row> rowsWithStatus(UUID batchId, String... statuses) {
        return jdbc.sql("select * from import_row where batch_id = ? and status = any(?) order by row_number")
                .params(batchId, statuses).query(this::mapRow).list();
    }

    Map<String, Integer> statusCounts(UUID batchId) {
        Map<String, Integer> counts = new java.util.HashMap<>();
        jdbc.sql("select status, count(*) as n from import_row where batch_id = ? group by status").param(batchId)
                .query((rs, row) -> counts.put(rs.getString("status"), rs.getInt("n"))).list();
        return counts;
    }

    /** Returns which fingerprint hashes are already committed in the workspace. */
    Set<String> committedFingerprints(UUID workspaceId, List<String> hashes) {
        if (hashes.isEmpty()) {
            return Set.of();
        }
        return new HashSet<>(jdbc.sql("select fingerprint from import_row where workspace_id = ? and status = "
                        + "'committed' and fingerprint = any(?)")
                .params(workspaceId, hashes.toArray(String[]::new)).query(String.class).list()
                .stream().map(String::trim).toList());
    }

    Optional<LocalDate> lastCommittedDate(UUID workspaceId, String accountId) {
        return jdbc.sql("select max(r.effective_date) from import_row r join import_batch b on b.id = r.batch_id "
                        + "where r.workspace_id = ? and b.account_id = ? and r.status = 'committed'")
                .params(workspaceId, accountId).query(LocalDate.class).optional();
    }

    void setRowStatus(UUID batchId, int rowNumber, String status, String errorCode) {
        jdbc.sql("update import_row set status = ?, error_code = ? where batch_id = ? and row_number = ?")
                .params(status, errorCode, batchId, rowNumber).update();
    }

    void forceRow(UUID batchId, int rowNumber, String fingerprintHash) {
        jdbc.sql("update import_row set status = 'new', fingerprint = ? where batch_id = ? and row_number = ?")
                .params(fingerprintHash, batchId, rowNumber).update();
    }

    /** Claims a row's fingerprint; throws on a duplicate committed elsewhere. */
    void markCommitted(UUID batchId, int rowNumber, UUID journalId, UUID commandId) {
        jdbc.sql("update import_row set status = 'committed', error_code = null, journal_id = ?, command_id = ? "
                        + "where batch_id = ? and row_number = ?")
                .params(journalId, commandId, batchId, rowNumber).update();
    }

    void setStatus(UUID batchId, String status, UUID jobId) {
        jdbc.sql("update import_batch set status = ?, job_id = coalesce(?, job_id) where id = ?")
                .params(status, jobId, batchId).update();
    }

    void complete(UUID batchId, String status, JsonNode result, Instant now) {
        jdbc.sql("update import_batch set status = ?, result = ?::jsonb, committed_at = coalesce(committed_at, ?) "
                        + "where id = ?")
                .params(status, json.writeValueAsString(result), Timestamp.from(now), batchId).update();
    }

    int purgeWorkspace(UUID workspaceId) {
        return jdbc.sql("delete from import_batch where workspace_id = ?").param(workspaceId).update();
    }

    private Batch mapBatch(ResultSet rs, int row) throws SQLException {
        String result = rs.getString("result");
        Timestamp committed = rs.getTimestamp("committed_at");
        return new Batch(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                rs.getString("account_id"), rs.getString("file_name"), json.readTree(rs.getString("mapping")),
                rs.getString("status"), rs.getInt("row_count"), rs.getInt("error_count"),
                json.readTree(rs.getString("summary")), result == null ? null : json.readTree(result),
                rs.getObject("job_id", UUID.class), rs.getTimestamp("created_at").toInstant(),
                committed == null ? null : committed.toInstant());
    }

    private Row mapRow(ResultSet rs, int row) throws SQLException {
        String matches = rs.getString("matches");
        long amount = rs.getLong("amount_minor");
        Long amountMinor = rs.wasNull() ? null : amount;
        String hash = rs.getString("fingerprint");
        return new Row(rs.getInt("row_number"), rs.getString("raw"), rs.getString("status"),
                rs.getString("error_code"), rs.getObject("effective_date", LocalDate.class), amountMinor,
                rs.getString("description"), rs.getString("reference"), rs.getString("dedupe_key"),
                hash == null ? null : hash.trim(), rs.getObject("journal_id", UUID.class),
                rs.getObject("command_id", UUID.class), matches == null ? null : json.readTree(matches));
    }
}
