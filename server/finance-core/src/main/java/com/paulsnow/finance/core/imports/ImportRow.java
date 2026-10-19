package com.paulsnow.finance.core.imports;

import java.time.LocalDate;
import java.util.List;

/**
 * One parsed statement row. {@code amountMinor} is signed from the
 * account's point of view: negative is money leaving the account, positive
 * money arriving.
 *
 * @param rowNumber   1-based record number in the file, counting the header record
 * @param date        transaction date
 * @param amountMinor signed amount in minor units
 * @param description trimmed description
 * @param reference   trimmed bank or provider reference, or null
 * @param fields      the raw fields, preserved as evidence (IMP 02)
 * @param rawText     the record's original text
 * @author Paul Snow
 * @since 0.0.0
 */
public record ImportRow(int rowNumber, LocalDate date, long amountMinor, String description, String reference,
        List<String> fields, String rawText) {

    public ImportRow {
        fields = List.copyOf(fields);
    }
}
