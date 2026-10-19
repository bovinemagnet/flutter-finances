package com.paulsnow.finance.core.ledger;

import java.util.ArrayList;
import java.util.List;

/**
 * The journals produced by correcting a posted journal.
 *
 * @param original    the original journal, now reversed
 * @param reversal    the reversal journal
 * @param replacement the replacement journal, or null when voiding
 * @author Paul Snow
 * @since 0.0.0
 */
public record CorrectionResult(Journal original, Journal reversal, Journal replacement) {

    /** Returns the original, the reversal and, when present, the replacement. */
    public List<Journal> journals() {
        List<Journal> journals = new ArrayList<>(List.of(original, reversal));
        if (replacement != null) {
            journals.add(replacement);
        }
        return List.copyOf(journals);
    }
}
