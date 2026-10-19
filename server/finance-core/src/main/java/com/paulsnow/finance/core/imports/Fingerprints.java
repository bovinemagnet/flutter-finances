package com.paulsnow.finance.core.imports;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Import row fingerprints (IMP 02; fixture {@code csv.fingerprint}). Client
 * and server compute the same keys, so re-importing a statement is
 * idempotent on both sides (A12) while two legitimate identical purchases
 * both survive (A11).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Fingerprints {

    private static final Pattern NON_ALPHANUMERIC = Pattern.compile("[^a-z0-9]+");

    private Fingerprints() {
    }

    /**
     * The fingerprint of a row before its occurrence count:
     * {@code ref|<account>|<reference>} with a reference, otherwise
     * {@code fp|<account>|<YYYY-MM-DD>|<amountMinor>|<normalised description>}.
     *
     * @param accountId account the rows belong to
     * @param row       parsed row
     * @return the base
     */
    public static String base(String accountId, ImportRow row) {
        String reference = row.reference() == null ? "" : CsvStatementParser.trim(row.reference());
        if (!reference.isEmpty()) {
            return "ref|" + accountId + "|" + reference;
        }
        return "fp|" + accountId + "|" + row.date() + "|" + row.amountMinor() + "|" + normalise(row.description());
    }

    /**
     * Fingerprints in row order: the base, {@code #}, and the 1-based
     * occurrence of that base so far.
     *
     * @param accountId account the rows belong to
     * @param rows      rows in file order
     * @return one fingerprint per row
     */
    public static List<String> assign(String accountId, List<ImportRow> rows) {
        Map<String, Integer> seen = new HashMap<>();
        List<String> fingerprints = new ArrayList<>(rows.size());
        for (ImportRow row : rows) {
            String base = base(accountId, row);
            int occurrence = seen.merge(base, 1, Integer::sum);
            fingerprints.add(base + "#" + occurrence);
        }
        return fingerprints;
    }

    /**
     * Lower-cases, replaces every run of characters other than ASCII
     * {@code a}-{@code z} and {@code 0}-{@code 9} with one space, and trims.
     *
     * @param text free text
     * @return normalised text
     */
    public static String normalise(String text) {
        return CsvStatementParser.trim(NON_ALPHANUMERIC.matcher(text.toLowerCase(Locale.ROOT)).replaceAll(" "));
    }
}
