package com.paulsnow.finance.core.planning;

import com.paulsnow.finance.core.ledger.WireNames;
import com.paulsnow.finance.core.money.Money;

/**
 * How a target's remaining budget carries into the next period (BUD 03).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum RolloverPolicy {

    /** Every period starts afresh. */
    NONE,

    /** Unspent money carries forward; overspending does not. */
    POSITIVE_ONLY,

    /** Unspent money and overspending both carry forward. */
    SIGNED;

    /**
     * Returns the opening rollover for the next period.
     *
     * @param remaining this period's remaining amount
     * @return the next period's opening rollover
     */
    public Money nextOpening(Money remaining) {
        return switch (this) {
            case NONE -> Money.zero(remaining.currency());
            case POSITIVE_ONLY -> remaining.isNegative() ? Money.zero(remaining.currency()) : remaining;
            case SIGNED -> remaining;
        };
    }

    /** Returns the wire name, for example {@code positiveOnly}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the policy
     * @throws IllegalArgumentException when unknown
     */
    public static RolloverPolicy fromWire(String wire) {
        return WireNames.lookup(RolloverPolicy.class, wire, RolloverPolicy::wire);
    }
}
