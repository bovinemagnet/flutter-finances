package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * Payment status of one scheduled occurrence.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum OccurrenceStatus {

    /** Due after today. */
    UPCOMING,

    /** Due today. */
    DUE,

    /** Paid in full, or settled with a changed amount. */
    PAID,

    /** Some money linked; the rest is outstanding. */
    PARTIALLY_PAID,

    /** Past due with account data current to the due date and no payment. */
    UNPAID,

    /**
     * Past due, but the account data is stale or missing, so a missing link
     * does not prove the bill is unpaid.
     */
    UNKNOWN,

    /** Skipped by a "this occurrence" edit. */
    SKIPPED;

    /** Returns the wire name, for example {@code partiallyPaid}. */
    public String wire() {
        return WireNames.camel(this);
    }
}
