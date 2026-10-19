package com.paulsnow.finance.core.ledger;

/**
 * What the user entered; drives presentation, not arithmetic.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum TransactionType {
    EXPENSE,
    INCOME,
    TRANSFER,
    REFUND,
    ADJUSTMENT,
    OPENING_BALANCE,
    REIMBURSABLE_EXPENSE,
    REIMBURSEMENT,
    REVERSAL;

    /** Returns the camelCase wire name, for example {@code openingBalance}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire camelCase name
     * @return the transaction type
     * @throws IllegalArgumentException when unknown
     */
    public static TransactionType fromWire(String wire) {
        return WireNames.lookup(TransactionType.class, wire, TransactionType::wire);
    }
}
