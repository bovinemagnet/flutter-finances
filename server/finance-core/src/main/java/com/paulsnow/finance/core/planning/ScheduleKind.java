package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;

/**
 * What a schedule does to cash.
 * <p>
 * A transfer has explicit forecast treatment: card statement payments and
 * loan instalments reduce the paying account; only the eligible cash side
 * appears in a cash forecast (PLAN 02).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum ScheduleKind {
    EXPENSE,
    INCOME,
    TRANSFER;

    /** Returns the wire name, for example {@code transfer}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the kind
     * @throws IllegalArgumentException when unknown
     */
    public static ScheduleKind fromWire(String wire) {
        return WireNames.lookup(ScheduleKind.class, wire, ScheduleKind::wire);
    }
}
