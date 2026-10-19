package com.paulsnow.finance.core.imports;

import java.util.List;

/**
 * Parsed rows and row-level errors, each in file order.
 *
 * @param rows   parsed rows
 * @param errors errors
 * @author Paul Snow
 * @since 0.0.0
 */
public record CsvParseResult(List<ImportRow> rows, List<ImportRowError> errors) {

    public CsvParseResult {
        rows = List.copyOf(rows);
        errors = List.copyOf(errors);
    }
}
