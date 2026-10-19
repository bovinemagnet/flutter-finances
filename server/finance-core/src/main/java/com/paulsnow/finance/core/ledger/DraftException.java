package com.paulsnow.finance.core.ledger;

/**
 * Raised when an entry cannot become a balanced journal.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class DraftException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    private final DraftError error;

    public DraftException(DraftError error) {
        super(error.code());
        this.error = error;
    }

    /** Returns the error code. */
    public DraftError error() {
        return error;
    }
}
