package com.paulsnow.finance.core.imports;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.paulsnow.finance.core.money.Money;
import com.paulsnow.finance.core.money.MoneyFormatException;
import com.paulsnow.finance.core.money.MoneyRangeException;

/**
 * Parses a bank's CSV statement with a {@link CsvMapping} (IMP 01; fixture
 * {@code csv.parse}). Pure and deterministic, and shared in behaviour with
 * the Dart client through the {@code documents.json} fixtures:
 * <ul>
 * <li>Reading follows RFC 4180: records end at CRLF, LF or CR outside
 * quotes; a field starting with {@code "} is quoted, {@code ""} inside it is
 * one quote, and delimiters and line breaks inside it are literal. A quote
 * anywhere else is kept literally. A leading U+FEFF is removed. Blank
 * records are skipped but counted. An unterminated quote reports
 * {@code UNTERMINATED_QUOTE} where it opened and stops reading.</li>
 * <li>A required column missing from the header gives
 * {@code COLUMN_NOT_FOUND} on row 1 per column and no rows.</li>
 * <li>Each record reports at most one error, in the order
 * {@code MISSING_FIELD}, {@code BAD_DATE}, amount errors
 * ({@code BAD_AMOUNT}, {@code MISSING_AMOUNT},
 * {@code BOTH_DEBIT_AND_CREDIT}), {@code ZERO_AMOUNT}.</li>
 * </ul>
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class CsvStatementParser {

    private static final Pattern TOKEN = Pattern.compile("yyyy|yy|MMM|MM|M|dd|d");

    private static final List<String> MONTHS = List.of("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug",
            "sep", "oct", "nov", "dec");

    private static final Map<String, DatePattern> DATE_PATTERNS = new ConcurrentHashMap<>();

    private record DatePattern(Pattern pattern, List<String> tokens) {
    }

    private record Record(int number, List<String> fields, String raw) {
    }

    private record Amount(Long minor, ImportErrorCode error) {
    }

    private CsvStatementParser() {
    }

    /**
     * Parses CSV text into rows.
     *
     * @param text     decoded file text
     * @param mapping  column mapping
     * @param exponent currency exponent of the workspace
     * @return rows and errors in file order
     */
    public static CsvParseResult parse(String text, CsvMapping mapping, int exponent) {
        String body = text.startsWith("﻿") ? text.substring(1) : text;
        List<ImportRowError> errors = new ArrayList<>();
        List<Record> records = read(body, mapping.delimiter(), errors);
        List<ImportRow> rows = new ArrayList<>();
        List<String> header = null;
        if (mapping.hasHeader() && !records.isEmpty()) {
            header = records.getFirst().fields();
            records = records.subList(1, records.size());
        }
        Integer date = required(mapping.dateColumn(), header, errors);
        Integer description = required(mapping.descriptionColumn(), header, errors);
        Integer amount = mapping.amountColumn() == null ? null : required(mapping.amountColumn(), header, errors);
        Integer debit = mapping.debitColumn() == null ? null : required(mapping.debitColumn(), header, errors);
        Integer credit = mapping.creditColumn() == null ? null : required(mapping.creditColumn(), header, errors);
        Integer reference = mapping.referenceColumn() == null ? null : mapping.referenceColumn().resolve(header);
        if (errors.stream().anyMatch(e -> e.code() == ImportErrorCode.COLUMN_NOT_FOUND)) {
            return new CsvParseResult(List.of(), errors);
        }
        int needed = Math.max(date, description);
        for (Integer index : new Integer[] { amount, debit, credit }) {
            if (index != null) {
                needed = Math.max(needed, index);
            }
        }
        for (Record record : records) {
            List<String> fields = record.fields();
            if (fields.size() <= needed) {
                errors.add(new ImportRowError(record.number(), ImportErrorCode.MISSING_FIELD));
                continue;
            }
            LocalDate parsedDate = parseDate(fields.get(date), mapping.dateFormat());
            if (parsedDate == null) {
                errors.add(new ImportRowError(record.number(), ImportErrorCode.BAD_DATE));
                continue;
            }
            Amount value = rowAmount(fields, mapping, exponent, amount, debit, credit);
            if (value.error() != null) {
                errors.add(new ImportRowError(record.number(), value.error()));
                continue;
            }
            String ref = reference != null && reference < fields.size() ? trim(fields.get(reference)) : "";
            rows.add(new ImportRow(record.number(), parsedDate, value.minor(), trim(fields.get(description)),
                    ref.isEmpty() ? null : ref, fields, record.raw()));
        }
        errors.sort(Comparator.comparingInt(ImportRowError::row));
        return new CsvParseResult(rows, errors);
    }

    /**
     * Reads one amount cell into minor units: trimmed; empty is no value;
     * {@code $} and spaces removed; {@code (x)} or a trailing {@code -}
     * negates; then the {@code money.parse} rules with the decimal
     * separator.
     *
     * @param text             cell text
     * @param exponent         currency exponent
     * @param decimalSeparator {@code .} or {@code ,}
     * @return minor units, null for an empty cell
     * @throws MoneyFormatException when the text is not an amount or is out of range
     */
    public static Long parseAmount(String text, int exponent, char decimalSeparator) {
        String t = trim(text).replace("$", "").replace(" ", "");
        if (t.isEmpty()) {
            return null;
        }
        boolean negate = false;
        if (t.length() > 2 && t.startsWith("(") && t.endsWith(")")) {
            negate = true;
            t = t.substring(1, t.length() - 1);
        } else if (t.length() > 1 && t.endsWith("-")) {
            negate = true;
            t = t.substring(0, t.length() - 1);
        }
        try {
            long minor = Money.parseMinor(t, exponent, decimalSeparator);
            return negate ? -minor : minor;
        } catch (MoneyRangeException e) {
            throw new MoneyFormatException("Amount out of range");
        }
    }

    /**
     * Parses a date with format tokens {@code yyyy}, {@code yy} (2000-2099),
     * {@code MMM} (English month abbreviation, any case), {@code MM}/{@code M}
     * and {@code dd}/{@code d} (one or two digits); other characters match
     * literally and anything after whitespace following the date is ignored.
     *
     * @param text   date text
     * @param format format
     * @return the date, or null when the text does not match or the date does not exist
     */
    public static LocalDate parseDate(String text, String format) {
        DatePattern compiled = DATE_PATTERNS.computeIfAbsent(format, CsvStatementParser::compileDate);
        Matcher match = compiled.pattern().matcher(trim(text));
        if (!match.matches()) {
            return null;
        }
        Integer year = null;
        Integer month = null;
        Integer day = null;
        for (int i = 0; i < compiled.tokens().size(); i++) {
            String value = match.group(i + 1);
            switch (compiled.tokens().get(i)) {
                case "yyyy" -> year = Integer.parseInt(value);
                case "yy" -> year = 2000 + Integer.parseInt(value);
                case "MMM" -> {
                    int index = MONTHS.indexOf(value.toLowerCase(Locale.ROOT));
                    if (index < 0) {
                        return null;
                    }
                    month = index + 1;
                }
                case "MM", "M" -> month = Integer.parseInt(value);
                default -> day = Integer.parseInt(value);
            }
        }
        if (year == null || month == null || day == null || month < 1 || month > 12 || day < 1
                || day > java.time.YearMonth.of(year, month).lengthOfMonth()) {
            return null;
        }
        return LocalDate.of(year, month, day);
    }

    /**
     * Trims whitespace as the Dart client does (Unicode white space and
     * U+FEFF), unlike {@link String#strip()}.
     *
     * @param text text
     * @return trimmed text
     */
    public static String trim(String text) {
        int start = 0;
        int end = text.length();
        while (start < end && isTrimmable(text.charAt(start))) {
            start++;
        }
        while (end > start && isTrimmable(text.charAt(end - 1))) {
            end--;
        }
        return text.substring(start, end);
    }

    private static boolean isTrimmable(char c) {
        return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680
                || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F
                || c == 0x3000 || c == 0xFEFF;
    }

    private static DatePattern compileDate(String format) {
        StringBuilder regex = new StringBuilder();
        List<String> tokens = new ArrayList<>();
        Matcher matcher = TOKEN.matcher(format);
        int last = 0;
        while (matcher.find()) {
            regex.append(Pattern.quote(format.substring(last, matcher.start())));
            String token = matcher.group();
            tokens.add(token);
            regex.append(switch (token) {
                case "yyyy" -> "([0-9]{4})";
                case "yy" -> "([0-9]{2})";
                case "MMM" -> "([A-Za-z]{3})";
                default -> "([0-9]{1,2})";
            });
            last = matcher.end();
        }
        regex.append(Pattern.quote(format.substring(last)));
        regex.append("(?:\\s.*)?");
        return new DatePattern(Pattern.compile(regex.toString(), Pattern.UNICODE_CHARACTER_CLASS), List.copyOf(tokens));
    }

    private static Integer required(CsvColumn column, List<String> header, List<ImportRowError> errors) {
        Integer index = column.resolve(header);
        if (index == null) {
            errors.add(new ImportRowError(1, ImportErrorCode.COLUMN_NOT_FOUND));
        }
        return index;
    }

    private static Amount rowAmount(List<String> fields, CsvMapping mapping, int exponent, Integer amountIndex,
            Integer debitIndex, Integer creditIndex) {
        long value;
        if (amountIndex != null) {
            Long parsed;
            try {
                parsed = parseAmount(fields.get(amountIndex), exponent, mapping.decimalSeparator());
            } catch (MoneyFormatException e) {
                return new Amount(null, ImportErrorCode.BAD_AMOUNT);
            }
            if (parsed == null) {
                return new Amount(null, ImportErrorCode.MISSING_AMOUNT);
            }
            value = mapping.debitSign() == DebitSign.NEGATIVE ? parsed : -parsed;
        } else {
            Long debit;
            Long credit;
            try {
                debit = parseAmount(fields.get(debitIndex), exponent, mapping.decimalSeparator());
                credit = parseAmount(fields.get(creditIndex), exponent, mapping.decimalSeparator());
            } catch (MoneyFormatException e) {
                return new Amount(null, ImportErrorCode.BAD_AMOUNT);
            }
            if (debit == null && credit == null) {
                return new Amount(null, ImportErrorCode.MISSING_AMOUNT);
            }
            long d = Math.abs(debit == null ? 0 : debit);
            long c = Math.abs(credit == null ? 0 : credit);
            if (d != 0 && c != 0) {
                return new Amount(null, ImportErrorCode.BOTH_DEBIT_AND_CREDIT);
            }
            value = c - d;
        }
        if (value == 0) {
            return new Amount(null, ImportErrorCode.ZERO_AMOUNT);
        }
        return new Amount(value, null);
    }

    private static List<Record> read(String text, char delimiter, List<ImportRowError> errors) {
        List<Record> records = new ArrayList<>();
        List<String> fields = new ArrayList<>();
        int number = 1;
        int recordStart = 0;
        int length = text.length();
        int i = 0;
        while (i < length) {
            char c = text.charAt(i);
            if (c == '"') {
                StringBuilder buffer = new StringBuilder();
                int startRecord = number;
                i++;
                boolean closed = false;
                while (i < length) {
                    c = text.charAt(i);
                    if (c == '"') {
                        if (i + 1 < length && text.charAt(i + 1) == '"') {
                            buffer.append('"');
                            i += 2;
                            continue;
                        }
                        closed = true;
                        i++;
                        break;
                    }
                    buffer.append(c);
                    i++;
                }
                if (!closed) {
                    errors.add(new ImportRowError(startRecord, ImportErrorCode.UNTERMINATED_QUOTE));
                    return records;
                }
                int tailStart = i;
                while (i < length) {
                    c = text.charAt(i);
                    if (c == delimiter || c == '\r' || c == '\n') {
                        break;
                    }
                    i++;
                }
                buffer.append(text, tailStart, i);
                fields.add(buffer.toString());
            } else {
                int start = i;
                while (i < length) {
                    c = text.charAt(i);
                    if (c == delimiter || c == '\r' || c == '\n') {
                        break;
                    }
                    i++;
                }
                fields.add(text.substring(start, i));
            }
            if (i >= length) {
                endRecord(records, fields, number, text.substring(recordStart, i));
                return records;
            }
            c = text.charAt(i);
            if (c == delimiter) {
                i++;
                if (i >= length) {
                    fields.add("");
                    endRecord(records, fields, number, text.substring(recordStart, i));
                    return records;
                }
                continue;
            }
            int end = i;
            i++;
            if (c == '\r' && i < length && text.charAt(i) == '\n') {
                i++;
            }
            endRecord(records, fields, number, text.substring(recordStart, end));
            fields = new ArrayList<>();
            number++;
            recordStart = i;
        }
        return records;
    }

    private static void endRecord(List<Record> records, List<String> fields, int number, String raw) {
        if (!(fields.size() == 1 && fields.getFirst().isEmpty())) {
            records.add(new Record(number, List.copyOf(fields), raw));
        }
    }
}
