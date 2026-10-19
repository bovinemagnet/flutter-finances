package com.paulsnow.finance.core.ledger;

/**
 * Whether a category records income or expenses.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum CategoryKind {
    INCOME,
    EXPENSE;

    /** Returns the wire name, {@code income} or {@code expense}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the category kind
     * @throws IllegalArgumentException when unknown
     */
    public static CategoryKind fromWire(String wire) {
        return WireNames.lookup(CategoryKind.class, wire, CategoryKind::wire);
    }

    public LedgerKind ledgerKind() {
        return this == INCOME ? LedgerKind.INCOME : LedgerKind.EXPENSE;
    }
}
