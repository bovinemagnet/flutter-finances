package com.paulsnow.finance.core.ledger;

/**
 * Stable journal validation codes shared with the Dart client (spec
 * fixtures, {@code journal.validate}).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum LedgerError {
    EMPTY("EMPTY"),
    TOO_FEW_POSTINGS("TOO_FEW_POSTINGS"),
    UNBALANCED("UNBALANCED"),
    MIXED_CURRENCY("MIXED_CURRENCY"),
    ZERO_AMOUNT("ZERO_AMOUNT"),
    OUT_OF_RANGE("OUT_OF_RANGE");

    private final String code;

    LedgerError(String code) {
        this.code = code;
    }

    /** Returns the wire code. */
    public String code() {
        return code;
    }
}
