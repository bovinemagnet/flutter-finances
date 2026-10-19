package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * How certain a forecast line is (PLAN 03); shown and exported separately.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum ForecastCertainty {

    /** Recorded in the ledger: posted or pending journals. */
    ACTUAL,

    /** Confirmed schedules and confirmed reservations. */
    COMMITTED,

    /** Produced or changed by a scenario. */
    HYPOTHETICAL;

    /** Returns the wire name, for example {@code committed}. */
    public String wire() {
        return WireNames.camel(this);
    }
}
