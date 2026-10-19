package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * Where a forecast line came from.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum ForecastSource {
    POSTED,
    PENDING,
    RESERVATION,
    SCHEDULE,
    SCENARIO;

    /** Returns the wire name, for example {@code reservation}. */
    public String wire() {
        return WireNames.camel(this);
    }
}
