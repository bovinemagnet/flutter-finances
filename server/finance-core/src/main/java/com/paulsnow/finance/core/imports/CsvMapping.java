package com.paulsnow.finance.core.imports;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A saved CSV mapping template (IMP 01), the {@code CsvMapping} JSON of
 * {@code spec/fixtures/README.md}. Exactly one amount layout is required: a
 * signed {@code amountColumn}, or both {@code debitColumn} and
 * {@code creditColumn}. Header-name columns need {@code hasHeader}.
 *
 * @param id                template identifier
 * @param name              template name
 * @param accountId         the user account the rows belong to
 * @param currencyCode      statement currency, default {@code AUD}
 * @param hasHeader         whether the first record names the columns
 * @param delimiter         one-character field separator
 * @param encoding          encoding used to decode the file bytes
 * @param decimalSeparator  {@code .} or {@code ,}; the other is grouping
 * @param dateColumn        date column
 * @param dateFormat        date format, default {@code dd/MM/yyyy}
 * @param descriptionColumn description column
 * @param amountColumn      signed amount column, or null
 * @param debitColumn       money-out column, or null
 * @param creditColumn      money-in column, or null
 * @param debitSign         how the signed column shows money out
 * @param referenceColumn   optional bank reference column
 * @author Paul Snow
 * @since 0.0.0
 */
public record CsvMapping(String id, String name, String accountId, String currencyCode, boolean hasHeader,
        char delimiter, TextEncoding encoding, char decimalSeparator, CsvColumn dateColumn, String dateFormat,
        CsvColumn descriptionColumn, CsvColumn amountColumn, CsvColumn debitColumn, CsvColumn creditColumn,
        DebitSign debitSign, CsvColumn referenceColumn) {

    public CsvMapping {
        currencyCode = currencyCode == null ? "AUD" : currencyCode;
        encoding = encoding == null ? TextEncoding.UTF8 : encoding;
        dateFormat = dateFormat == null ? "dd/MM/yyyy" : dateFormat;
        debitSign = debitSign == null ? DebitSign.NEGATIVE : debitSign;
        if (dateColumn == null || descriptionColumn == null) {
            throw new IllegalArgumentException("Date and description columns are required");
        }
        boolean signed = amountColumn != null;
        boolean split = debitColumn != null || creditColumn != null;
        if (signed == split) {
            throw new IllegalArgumentException("Choose either a signed amount column or debit and credit columns");
        }
        if (split && (debitColumn == null || creditColumn == null)) {
            throw new IllegalArgumentException("Both debit and credit columns are required");
        }
        if (decimalSeparator != '.' && decimalSeparator != ',') {
            throw new IllegalArgumentException("The decimal separator must be . or ,");
        }
        if (!hasHeader) {
            for (CsvColumn column : new CsvColumn[] { dateColumn, descriptionColumn, amountColumn, debitColumn,
                    creditColumn, referenceColumn }) {
                if (column != null && column.header() != null) {
                    throw new IllegalArgumentException("Header names need a file with a header row");
                }
            }
        }
    }

    /**
     * Reads the mapping JSON (as plain Java values); omitted settings take
     * their defaults.
     *
     * @param json mapping properties
     * @return the mapping
     * @throws IllegalArgumentException when the mapping is invalid
     */
    public static CsvMapping fromMap(Map<String, Object> json) {
        try {
            return new CsvMapping(string(json, "id", ""), string(json, "name", ""), string(json, "accountId", ""),
                    string(json, "currency", "AUD"), bool(json, "hasHeader", true), character(json, "delimiter", ','),
                    TextEncoding.fromWire(string(json, "encoding", "utf8")),
                    character(json, "decimalSeparator", '.'), CsvColumn.of(json.get("dateColumn")),
                    string(json, "dateFormat", "dd/MM/yyyy"), CsvColumn.of(json.get("descriptionColumn")),
                    CsvColumn.of(json.get("amountColumn")), CsvColumn.of(json.get("debitColumn")),
                    CsvColumn.of(json.get("creditColumn")), DebitSign.fromWire(string(json, "debitSign", "negative")),
                    CsvColumn.of(json.get("referenceColumn")));
        } catch (ClassCastException | ArithmeticException e) {
            throw new IllegalArgumentException("Invalid mapping", e);
        }
    }

    /** Writes the mapping JSON as plain Java values. */
    public Map<String, Object> toMap() {
        Map<String, Object> json = new LinkedHashMap<>();
        json.put("id", id);
        json.put("name", name);
        json.put("accountId", accountId);
        json.put("currency", currencyCode);
        json.put("hasHeader", hasHeader);
        json.put("delimiter", String.valueOf(delimiter));
        json.put("encoding", encoding.wire());
        json.put("decimalSeparator", String.valueOf(decimalSeparator));
        json.put("dateColumn", dateColumn.toValue());
        json.put("dateFormat", dateFormat);
        json.put("descriptionColumn", descriptionColumn.toValue());
        json.put("amountColumn", amountColumn == null ? null : amountColumn.toValue());
        json.put("debitColumn", debitColumn == null ? null : debitColumn.toValue());
        json.put("creditColumn", creditColumn == null ? null : creditColumn.toValue());
        json.put("debitSign", debitSign.wire());
        json.put("referenceColumn", referenceColumn == null ? null : referenceColumn.toValue());
        return json;
    }

    private static String string(Map<String, Object> json, String key, String fallback) {
        Object value = json.get(key);
        return value == null ? fallback : (String) value;
    }

    private static boolean bool(Map<String, Object> json, String key, boolean fallback) {
        Object value = json.get(key);
        return value == null ? fallback : (Boolean) value;
    }

    private static char character(Map<String, Object> json, String key, char fallback) {
        String value = string(json, key, null);
        if (value == null) {
            return fallback;
        }
        if (value.length() != 1) {
            throw new IllegalArgumentException(key + " must be one character");
        }
        return value.charAt(0);
    }
}
