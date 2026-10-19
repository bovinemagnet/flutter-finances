package com.paulsnow.finance.core.fixtures;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import com.paulsnow.finance.core.documents.ContentSniffer;
import com.paulsnow.finance.core.documents.DocumentContentType;
import com.paulsnow.finance.core.documents.PdfInspector;
import com.paulsnow.finance.core.imports.CsvMapping;
import com.paulsnow.finance.core.imports.CsvParseResult;
import com.paulsnow.finance.core.imports.CsvSanitiser;
import com.paulsnow.finance.core.imports.CsvStatementParser;
import com.paulsnow.finance.core.imports.Fingerprints;
import com.paulsnow.finance.core.imports.ImportRow;
import com.paulsnow.finance.core.imports.ImportRowError;

import tools.jackson.databind.JsonNode;

/**
 * Java handlers for the documents fixture operations, mirroring
 * {@code packages/finance_core/test/fixtures/documents_ops.dart}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class DocumentsFixtureOps {

    private DocumentsFixtureOps() {
    }

    static Map<String, FixtureOp> all() {
        Map<String, FixtureOp> ops = new LinkedHashMap<>();
        ops.put("csv.parse", DocumentsFixtureOps::csvParse);
        ops.put("csv.fingerprint", DocumentsFixtureOps::csvFingerprint);
        ops.put("csv.sanitise", DocumentsFixtureOps::csvSanitise);
        ops.put("content.sniff", DocumentsFixtureOps::contentSniff);
        ops.put("pdf.inspect", DocumentsFixtureOps::pdfInspect);
        return Map.copyOf(ops);
    }

    private static void csvParse(JsonNode input, JsonNode expected) {
        CsvMapping mapping = CsvMapping.fromMap(toMap(input.path("mapping")));
        CsvParseResult result = CsvStatementParser.parse(input.path("text").asString(), mapping,
                input.path("exponent").asInt(2));
        List<Map<String, Object>> rows = new ArrayList<>();
        for (ImportRow row : result.rows()) {
            Map<String, Object> json = new LinkedHashMap<>();
            json.put("row", row.rowNumber());
            json.put("date", row.date().toString());
            json.put("amountMinor", row.amountMinor());
            json.put("description", row.description());
            if (row.reference() != null) {
                json.put("reference", row.reference());
            }
            rows.add(json);
        }
        List<Map<String, Object>> wantRows = new ArrayList<>();
        for (JsonNode raw : expected.path("rows")) {
            Map<String, Object> json = new LinkedHashMap<>();
            json.put("row", raw.path("row").asInt());
            json.put("date", raw.path("date").asString());
            json.put("amountMinor", raw.path("amountMinor").asLong());
            json.put("description", raw.path("description").asString());
            if (raw.has("reference")) {
                json.put("reference", raw.path("reference").asString());
            }
            wantRows.add(json);
        }
        assertThat(rows).as("rows").isEqualTo(wantRows);
        List<String> errors = new ArrayList<>();
        for (ImportRowError error : result.errors()) {
            errors.add(error.row() + ":" + error.code().code());
        }
        List<String> wantErrors = new ArrayList<>();
        expected.path("errors").forEach(e -> wantErrors.add(e.path("row").asInt() + ":" + e.path("code").asString()));
        assertThat(errors).as("errors").isEqualTo(wantErrors);
    }

    private static void csvFingerprint(JsonNode input, JsonNode expected) {
        List<ImportRow> rows = new ArrayList<>();
        int number = 1;
        for (JsonNode raw : input.path("rows")) {
            rows.add(new ImportRow(number++, LocalDate.parse(raw.path("date").asString()),
                    raw.path("amountMinor").asLong(), raw.path("description").asString(),
                    raw.hasNonNull("reference") ? raw.path("reference").asString() : null, List.of(), ""));
        }
        List<String> want = new ArrayList<>();
        expected.path("fingerprints").forEach(f -> want.add(f.asString()));
        assertThat(Fingerprints.assign(input.path("account").asString(), rows)).isEqualTo(want);
    }

    private static void csvSanitise(JsonNode input, JsonNode expected) {
        assertThat(CsvSanitiser.sanitise(input.path("value").asString()))
                .isEqualTo(expected.path("value").asString());
    }

    private static void contentSniff(JsonNode input, JsonNode expected) {
        byte[] bytes = Base64.getDecoder().decode(input.path("base64").asString());
        Map<String, String> actual;
        if (bytes.length == 0) {
            actual = Map.of("error", "EMPTY_FILE");
        } else {
            Optional<DocumentContentType> type = ContentSniffer.sniff(bytes);
            actual = type.map(t -> Map.of("contentType", t.mimeType()))
                    .orElseGet(() -> Map.of("error", "UNSUPPORTED_TYPE"));
        }
        Map<String, String> want = new LinkedHashMap<>();
        expected.properties().forEach(e -> want.put(e.getKey(), e.getValue().asString()));
        assertThat(actual).isEqualTo(want);
    }

    private static void pdfInspect(JsonNode input, JsonNode expected) {
        PdfInspector.PdfInfo info = PdfInspector.inspect(Base64.getDecoder().decode(input.path("base64").asString()));
        Map<String, Object> actual = new LinkedHashMap<>();
        actual.put("readable", info.readable());
        actual.put("encrypted", info.encrypted());
        actual.put("pageCount", info.pageCount());
        assertThat(actual).isEqualTo(toMap(expected));
    }

    /** Converts a JSON object to plain Java values (strings, integers, booleans). */
    static Map<String, Object> toMap(JsonNode node) {
        Map<String, Object> map = new LinkedHashMap<>();
        node.properties().forEach(e -> {
            JsonNode value = e.getValue();
            Object plain = value.isNull() ? null
                    : value.isBoolean() ? (Object) value.asBoolean()
                    : value.isIntegralNumber() ? (Object) value.asInt()
                    : value.asString();
            map.put(e.getKey(), plain);
        });
        return map;
    }
}
