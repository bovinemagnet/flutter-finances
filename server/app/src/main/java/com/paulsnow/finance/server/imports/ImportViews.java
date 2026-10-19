package com.paulsnow.finance.server.imports;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonInclude;

import tools.jackson.databind.JsonNode;

/**
 * Request and response bodies of the import API.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class ImportViews {

    private ImportViews() {
    }

    /**
     * A statement to preview.
     *
     * @param fileName          original file name, for the user's reference
     * @param contentBase64     file bytes, decoded with the mapping's encoding
     * @param mapping           the shared {@code CsvMapping} JSON, including {@code accountId}
     * @param outflowCategoryId expense category for money out
     * @param inflowCategoryId  income category for money in
     */
    record PreviewRequest(String fileName, String contentBase64, JsonNode mapping, String outflowCategoryId,
            String inflowCategoryId) {
    }

    /**
     * Per-row decisions for a commit, keyed by row number:
     * {@code import} (also forces a duplicate) or {@code skip}.
     *
     * @param decisions decisions
     */
    record CommitRequest(Map<String, String> decisions) {
    }

    /** A candidate the user may review; never acted on automatically. */
    record MatchView(String kind, UUID journalId, LocalDate date) {
    }

    /** One statement row. */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    record RowView(int rowNumber, LocalDate date, String description, Long amountMinor, String status,
            String errorCode, String fingerprint, UUID journalId, List<MatchView> matches) {
    }

    /** Statement totals of the parsed rows, in minor units. */
    record Totals(long inflowMinor, long outflowMinor, long netMinor) {
    }

    /** Days with no imported data between the previous statement and this one. */
    record DateGap(LocalDate from, LocalDate to) {
    }

    /** An import batch with a page of its rows. */
    record BatchView(UUID batchId, String status, String accountId, String fileName, int rowCount, int errorCount,
            int newCount, int duplicateCount, Totals totals, LocalDate firstDate, LocalDate lastDate,
            DateGap dateGap, JsonNode result, UUID jobId, int rowsOffset, List<RowView> rows) {
    }
}
