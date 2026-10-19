package com.paulsnow.finance.core.reports;

import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import com.paulsnow.finance.core.money.Money;

/**
 * Tabular report data (REP 01), matching the client's {@code Report}: the
 * same rows feed a chart and the accessible table beside it.
 *
 * @param title    report title
 * @param keyLabel heading of the row label column, for example {@code Category}
 * @param columns  value columns
 * @param rows     rows in display order
 * @param range    date range, or null for a point-in-time report
 * @param asOf     point in time, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record Report(String title, String keyLabel, List<Column> columns, List<Row> rows, DateRange range,
        LocalDate asOf) {

    /** Whether a column holds money or a count. */
    public enum ValueKind {
        MONEY,
        COUNT
    }

    /**
     * A value column.
     *
     * @param key   stable key used in {@link Row#amounts()}
     * @param label display label
     * @param kind  money or count
     */
    public record Column(String key, String label, ValueKind kind) {

        public Column(String key, String label) {
            this(key, label, ValueKind.MONEY);
        }
    }

    /**
     * One row with the source journals behind it for drill-through.
     *
     * @param key        stable key
     * @param label      display label
     * @param amounts    money per column key
     * @param counts     counts per column key
     * @param journalIds journals that make up the row, in effective date order
     */
    public record Row(String key, String label, Map<String, Money> amounts, Map<String, Integer> counts,
            List<String> journalIds) {

        public Row {
            Objects.requireNonNull(key, "key");
            amounts = java.util.Collections.unmodifiableMap(new LinkedHashMap<>(amounts));
            counts = java.util.Collections.unmodifiableMap(new LinkedHashMap<>(counts));
            journalIds = List.copyOf(journalIds);
        }

        /**
         * Returns the money in a column.
         *
         * @param column column key
         * @return the amount
         * @throws IllegalArgumentException when the row has no such money column
         */
        public Money amount(String column) {
            Money value = amounts.get(column);
            if (value == null) {
                throw new IllegalArgumentException("Unknown column " + column);
            }
            return value;
        }
    }

    public Report {
        columns = List.copyOf(columns);
        rows = List.copyOf(rows);
    }

    /**
     * Returns the row with {@code key}.
     *
     * @param key row key
     * @return the row, or null
     */
    public Row row(String key) {
        for (Row row : rows) {
            if (row.key().equals(key)) {
                return row;
            }
        }
        return null;
    }
}
