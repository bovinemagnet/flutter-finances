package com.paulsnow.finance.core.imports;

/**
 * Row-level CSV import problems (IMP 01), shared with the Dart client.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum ImportErrorCode {
    UNTERMINATED_QUOTE("UNTERMINATED_QUOTE"),
    COLUMN_NOT_FOUND("COLUMN_NOT_FOUND"),
    MISSING_FIELD("MISSING_FIELD"),
    BAD_DATE("BAD_DATE"),
    BAD_AMOUNT("BAD_AMOUNT"),
    MISSING_AMOUNT("MISSING_AMOUNT"),
    BOTH_DEBIT_AND_CREDIT("BOTH_DEBIT_AND_CREDIT"),
    ZERO_AMOUNT("ZERO_AMOUNT");

    private final String code;

    ImportErrorCode(String code) {
        this.code = code;
    }

    /** Returns the wire code. */
    public String code() {
        return code;
    }
}
