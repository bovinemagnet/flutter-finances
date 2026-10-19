package com.paulsnow.finance.core.imports;

/**
 * How a single signed amount column shows money leaving the account.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum DebitSign {
    /** Debits are negative, as most bank exports show them. */
    NEGATIVE,
    /** Debits are positive, as many card statements show them; signs are flipped. */
    POSITIVE;

    /** Returns {@code negative} or {@code positive}. */
    public String wire() {
        return this == NEGATIVE ? "negative" : "positive";
    }

    /**
     * Resolves {@code negative} or {@code positive}.
     *
     * @param wire wire name
     * @return the sign
     */
    public static DebitSign fromWire(String wire) {
        return switch (wire) {
            case "negative" -> NEGATIVE;
            case "positive" -> POSITIVE;
            default -> throw new IllegalArgumentException("Unknown debit sign");
        };
    }
}
