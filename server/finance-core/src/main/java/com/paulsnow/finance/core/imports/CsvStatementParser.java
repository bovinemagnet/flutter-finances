package com.paulsnow.finance.core.imports;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.time.format.ResolverStyle;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.money.MoneyFormatException;
import com.paulsnow.finance.core.money.MoneyRangeException;

/**
 * Parses a bank's CSV statement into dated, signed amounts with a
 * {@link CsvMapping} (IMP 01). Pure and deterministic: text in, rows and
 * row-level errors out, so the Dart client and the server can share
 * fixtures for it.
 * <p>
 * Rules:
 * <ul>
 * <li>RFC 4180 records: quoted fields may contain the delimiter, doubled
 * quotes and line breaks; CRLF, LF and CR all end a record; a leading
 * byte-order mark is ignored; blank records are skipped.</li>
 * <li>{@code rowNumber} is the 1-based position of the record in the file,
 * the header counting as record 1, so it matches spreadsheet rows when no
 * field spans lines.</li>
 * <li>Amounts are exact ({@link Money#parseMinor}); {@code $} signs are
 * ignored and parentheses mean negative. {@code amountMinor} is from the
 * account's point of view: positive is money in, negative money out. With
 * debit and credit columns exactly one must be non-zero.</li>
 * <li>Each failing record yields one error with the first failing check, in
 * the order column count, date, description, amount, currency.</li>
 * </ul>
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class CsvStatementParser {

    /**
     * A parsed statement line.
     *
     * @param rowNumber   1-based record number in the file
     * @param date        transaction date
     * @param description trimmed description
     * @param amountMinor signed minor units, positive is money in
     * @param currency    workspace currency code
     * @param reference   bank reference, or null
     * @param raw         the record's original text
     */
    public record CsvRow(int rowNumber, LocalDate date, String description, long amountMinor, String currency,
            String reference, String raw) {
    }

    /**
     * A record that could not be parsed.
     *
     * @param rowNumber 1-based record number in the file (0 for a mapping problem)
     * @param code      stable code: {@code COLUMN_COUNT}, {@code DATE_FORMAT}, {@code MISSING_FIELD},
     *                  {@code AMOUNT_FORMAT}, {@code OUT_OF_RANGE}, {@code ZERO_AMOUNT},
     *                  {@code CURRENCY_MISMATCH}, {@code UNKNOWN_COLUMN}, {@code INVALID_MAPPING} or
     *                  {@code UNTERMINATED_QUOTE}
     * @param column    the mapped column at fault, or null
     * @param raw       the record's original text, or null
     */
    public record CsvError(int rowNumber, String code, String column, String raw) {
    }

    /**
     * Parsed rows and errors, each in file order.
     *
     * @param rows   parsed rows
     * @param errors row-level errors
     */
    public record CsvResult(List<CsvRow> rows, List<CsvError> errors) {
    }

    private record Record(int number, List<String> fields, String raw) {
    }

    private CsvStatementParser() {
    }

    /**
     * Parses a statement.
     *
     * @param text    decoded file text
     * @param mapping column mapping
     * @return rows and errors
     */
    public static CsvResult parse(String text, CsvMapping mapping) {
        List<CsvRow> rows = new ArrayList<>();
        List<CsvError> errors = new ArrayList<>();
        if (mapping.dateColumn() == null || mapping.descriptionColumn() == null
                || (mapping.amountColumn() == null && mapping.debitColumn() == null
                        && mapping.creditColumn() == null)) {
            errors.add(new CsvError(0, "INVALID_MAPPING", null, null));
            return new CsvResult(rows, errors);
        }
        List<Record> records = records(text.startsWith("﻿") ? text.substring(1) : text, mapping.delimiter(),
                errors);
        Map<String, Integer> columns = new HashMap<>();
        int first = 0;
        if (mapping.hasHeader() && !records.isEmpty()) {
            Record header = records.getFirst();
            for (int i = 0; i < header.fields().size(); i++) {
                columns.putIfAbsent(normalise(header.fields().get(i)), i);
            }
            first = 1;
        }
        Map<String, Integer> indexes = new HashMap<>();
        for (String column : new String[] { mapping.dateColumn(), mapping.descriptionColumn(), mapping.amountColumn(),
                mapping.debitColumn(), mapping.creditColumn(), mapping.currencyColumn(), mapping.referenceColumn() }) {
            if (column == null) {
                continue;
            }
            Integer index = mapping.hasHeader() ? columns.get(normalise(column)) : position(column);
            if (index == null) {
                errors.clear();
                errors.add(new CsvError(mapping.hasHeader() ? 1 : 0, "UNKNOWN_COLUMN", column, null));
                return new CsvResult(List.of(), List.copyOf(errors));
            }
            indexes.put(column, index);
        }
        int needed = indexes.values().stream().mapToInt(Integer::intValue).max().orElse(0) + 1;
        DateTimeFormatter dates = DateTimeFormatter.ofPattern(strictPattern(mapping.dateFormat()), Locale.ROOT)
                .withResolverStyle(ResolverStyle.STRICT);
        for (Record record : records.subList(first, records.size())) {
            Object outcome = parseRecord(record, mapping, indexes, needed, dates);
            if (outcome instanceof CsvRow row) {
                rows.add(row);
            } else {
                errors.add((CsvError) outcome);
            }
        }
        errors.sort((a, b) -> Integer.compare(a.rowNumber(), b.rowNumber()));
        return new CsvResult(List.copyOf(rows), List.copyOf(errors));
    }

    private static Object parseRecord(Record record, CsvMapping mapping, Map<String, Integer> indexes, int needed,
            DateTimeFormatter dates) {
        if (record.fields().size() < needed) {
            return error(record, "COLUMN_COUNT", null);
        }
        LocalDate date;
        try {
            date = LocalDate.parse(field(record, indexes, mapping.dateColumn()), dates);
        } catch (DateTimeParseException e) {
            return error(record, "DATE_FORMAT", mapping.dateColumn());
        }
        String description = field(record, indexes, mapping.descriptionColumn());
        if (description.isEmpty()) {
            return error(record, "MISSING_FIELD", mapping.descriptionColumn());
        }
        long amount;
        String amountColumn = mapping.amountColumn() != null ? mapping.amountColumn()
                : mapping.debitColumn() != null ? mapping.debitColumn() : mapping.creditColumn();
        try {
            if (mapping.amountColumn() != null) {
                String text = field(record, indexes, mapping.amountColumn());
                if (text.isEmpty()) {
                    return error(record, "MISSING_FIELD", amountColumn);
                }
                amount = amount(text, mapping);
                if (mapping.signConvention() == CsvMapping.SignConvention.POSITIVE_IS_OUTFLOW) {
                    amount = -amount;
                }
            } else {
                String debit = mapping.debitColumn() == null ? "" : field(record, indexes, mapping.debitColumn());
                String credit = mapping.creditColumn() == null ? "" : field(record, indexes, mapping.creditColumn());
                if (debit.isEmpty() && credit.isEmpty()) {
                    return error(record, "MISSING_FIELD", amountColumn);
                }
                long out = debit.isEmpty() ? 0 : Math.abs(amount(debit, mapping));
                long in = credit.isEmpty() ? 0 : Math.abs(amount(credit, mapping));
                if (out != 0 && in != 0) {
                    return error(record, "AMOUNT_FORMAT", amountColumn);
                }
                amount = in - out;
            }
        } catch (MoneyRangeException e) {
            return error(record, "OUT_OF_RANGE", amountColumn);
        } catch (MoneyFormatException e) {
            return error(record, "AMOUNT_FORMAT", amountColumn);
        }
        if (amount == 0) {
            return error(record, "ZERO_AMOUNT", amountColumn);
        }
        if (mapping.currencyColumn() != null) {
            String currency = field(record, indexes, mapping.currencyColumn()).toUpperCase(Locale.ROOT);
            if (!currency.isEmpty() && !currency.equals(mapping.currency())) {
                return error(record, "CURRENCY_MISMATCH", mapping.currencyColumn());
            }
        }
        String reference = mapping.referenceColumn() == null ? "" : field(record, indexes, mapping.referenceColumn());
        return new CsvRow(record.number(), date, description, amount, mapping.currency(),
                reference.isEmpty() ? null : reference, record.raw());
    }

    private static long amount(String text, CsvMapping mapping) {
        String cleaned = text.replace("$", "").strip();
        boolean parenthesised = cleaned.startsWith("(") && cleaned.endsWith(")");
        if (parenthesised) {
            cleaned = cleaned.substring(1, cleaned.length() - 1).strip();
            if (cleaned.startsWith("-") || cleaned.startsWith("+")) {
                throw new MoneyFormatException("Signed amount in parentheses");
            }
        }
        if (cleaned.isEmpty()) {
            throw new MoneyFormatException("Empty amount");
        }
        long minor = Money.parseMinor(cleaned, mapping.exponent(), mapping.decimalSeparator());
        return parenthesised ? -minor : minor;
    }

    private static List<Record> records(String text, char delimiter, List<CsvError> errors) {
        List<Record> records = new ArrayList<>();
        List<String> fields = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        boolean inQuotes = false;
        boolean fieldStart = true;
        int recordStart = 0;
        int number = 1;
        int i = 0;
        while (i < text.length()) {
            char c = text.charAt(i);
            if (inQuotes) {
                if (c == '"') {
                    if (i + 1 < text.length() && text.charAt(i + 1) == '"') {
                        field.append('"');
                        i++;
                    } else {
                        inQuotes = false;
                    }
                } else {
                    field.append(c);
                }
            } else if (c == '"' && fieldStart) {
                inQuotes = true;
                fieldStart = false;
            } else if (c == delimiter) {
                fields.add(field.toString());
                field.setLength(0);
                fieldStart = true;
            } else if (c == '\r' || c == '\n') {
                fields.add(field.toString());
                addRecord(records, number, fields, text.substring(recordStart, i));
                fields = new ArrayList<>();
                field.setLength(0);
                fieldStart = true;
                number++;
                if (c == '\r' && i + 1 < text.length() && text.charAt(i + 1) == '\n') {
                    i++;
                }
                recordStart = i + 1;
            } else {
                field.append(c);
                fieldStart = false;
            }
            i++;
        }
        if (inQuotes) {
            errors.add(new CsvError(number, "UNTERMINATED_QUOTE", null, text.substring(recordStart)));
        } else if (recordStart < text.length()) {
            fields.add(field.toString());
            addRecord(records, number, fields, text.substring(recordStart));
        }
        return records;
    }

    private static void addRecord(List<Record> records, int number, List<String> fields, String raw) {
        if (fields.size() == 1 && fields.getFirst().isBlank()) {
            return;
        }
        records.add(new Record(number, List.copyOf(fields), raw));
    }

    private static String field(Record record, Map<String, Integer> indexes, String column) {
        return record.fields().get(indexes.get(column)).strip();
    }

    private static CsvError error(Record record, String code, String column) {
        return new CsvError(record.number(), code, column, record.raw());
    }

    private static Integer position(String column) {
        try {
            int index = Integer.parseInt(column.strip());
            return index >= 0 ? index : null;
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static String normalise(String header) {
        return header.strip().toLowerCase(Locale.ROOT);
    }

    /** STRICT resolution needs proleptic years, so {@code y} becomes {@code u}. */
    private static String strictPattern(String pattern) {
        return pattern.replace('y', 'u');
    }
}
