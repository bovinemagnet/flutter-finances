package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * Budget period lengths (BUD 02).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum PeriodCycle {
    MONTH,
    WEEK,
    FORTNIGHT,
    CUSTOM;

    /** Returns the wire name, for example {@code fortnight}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the cycle
     * @throws IllegalArgumentException when unknown
     */
    public static PeriodCycle fromWire(String wire) {
        return WireNames.lookup(PeriodCycle.class, wire, PeriodCycle::wire);
    }
}
