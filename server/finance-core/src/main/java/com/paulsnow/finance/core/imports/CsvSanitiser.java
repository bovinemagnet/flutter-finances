package com.paulsnow.finance.core.imports;

/**
 * Neutralises spreadsheet formula injection in user text written to CSV
 * (EXP 01, fixture {@code csv.sanitise}).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class CsvSanitiser {

    private static final String FORMULA_PREFIXES = "=+-@\t\r";

    private CsvSanitiser() {
    }

    /**
     * Prefixes an apostrophe when the value starts with {@code =}, {@code +},
     * {@code -}, {@code @}, a tab or a carriage return. Apply it to text
     * fields only; numeric amounts are written unsanitised.
     *
     * @param value text
     * @return the safe text
     */
    public static String sanitise(String value) {
        return !value.isEmpty() && FORMULA_PREFIXES.indexOf(value.charAt(0)) >= 0 ? "'" + value : value;
    }

    /**
     * Quotes a field when it contains the delimiter, a quote or a line break,
     * doubling embedded quotes (RFC 4180).
     *
     * @param value     field text
     * @param delimiter delimiter
     * @return the encoded field
     */
    public static String encodeField(String value, char delimiter) {
        boolean quote = value.indexOf(delimiter) >= 0 || value.indexOf('"') >= 0 || value.indexOf('\n') >= 0
                || value.indexOf('\r') >= 0;
        return quote ? "\"" + value.replace("\"", "\"\"") + "\"" : value;
    }
}
