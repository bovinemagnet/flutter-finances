package com.paulsnow.finance.core.ledger;

/**
 * Stable codes for entries that cannot become journals (spec fixtures,
 * {@code ledger.scenario}).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum DraftError {
    UNKNOWN_ACCOUNT("UNKNOWN_ACCOUNT"),
    UNKNOWN_CATEGORY("UNKNOWN_CATEGORY"),
    WRONG_CATEGORY_KIND("WRONG_CATEGORY_KIND"),
    SPLIT_MISMATCH("SPLIT_MISMATCH"),
    MISSING_SPLITS("MISSING_SPLITS"),
    NON_POSITIVE_AMOUNT("NON_POSITIVE_AMOUNT"),
    SAME_ACCOUNT("SAME_ACCOUNT"),
    CURRENCY_MISMATCH("CURRENCY_MISMATCH"),
    INVALID_STATUS("INVALID_STATUS");

    private final String code;

    DraftError(String code) {
        this.code = code;
    }

    /** Returns the wire code. */
    public String code() {
        return code;
    }
}
