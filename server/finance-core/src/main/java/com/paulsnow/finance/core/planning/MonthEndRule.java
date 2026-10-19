package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * The explicit end-of-month rule for month-based repeats.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum MonthEndRule {

    /**
     * Keep the intended day of month; in shorter months use the last day,
     * then return to the intended day when the month is long enough again.
     */
    CLAMP,

    /** Always fall on the last day of the month. The start must be a month end. */
    LAST_DAY;

    /** Returns the wire name, {@code clamp} or {@code lastDay}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the rule
     * @throws IllegalArgumentException when unknown
     */
    public static MonthEndRule fromWire(String wire) {
        return WireNames.lookup(MonthEndRule.class, wire, MonthEndRule::wire);
    }
}
