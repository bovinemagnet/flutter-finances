package com.paulsnow.finance.core.imports;

import java.util.List;
import java.util.Locale;

/**
 * A column chosen by zero-based position or by header name.
 *
 * @param index  zero-based position, or null
 * @param header header name, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record CsvColumn(Integer index, String header) {

    public CsvColumn {
        if ((index == null) == (header == null)) {
            throw new IllegalArgumentException("A column is either an index or a header name");
        }
    }

    /**
     * Reads {@code 0} (an index) or {@code "Date"} (a header name).
     *
     * @param value Integer, Long or String
     * @return the column, or null for null
     */
    public static CsvColumn of(Object value) {
        return switch (value) {
            case null -> null;
            case Integer i -> new CsvColumn(i, null);
            case Long l -> new CsvColumn(Math.toIntExact(l), null);
            case String s -> new CsvColumn(null, s);
            default -> throw new IllegalArgumentException("Column must be an index or a header name");
        };
    }

    /** Returns the index or header name, for JSON. */
    public Object toValue() {
        return index != null ? index : header;
    }

    /**
     * Returns the field position in records. Header names match after
     * trimming, ignoring case.
     *
     * @param headerRow header fields, or null without a header
     * @return the position, or null when the header lacks it
     */
    public Integer resolve(List<String> headerRow) {
        if (index != null) {
            return index;
        }
        if (headerRow == null) {
            return null;
        }
        String wanted = CsvStatementParser.trim(header).toLowerCase(Locale.ROOT);
        for (int i = 0; i < headerRow.size(); i++) {
            if (CsvStatementParser.trim(headerRow.get(i)).toLowerCase(Locale.ROOT).equals(wanted)) {
                return i;
            }
        }
        return null;
    }
}
