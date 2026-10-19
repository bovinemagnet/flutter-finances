package com.paulsnow.finance.core.ledger;

/**
 * Lifecycle of a journal (FIN 07).
 * <p>
 * {@code posted} and {@code reversed} journals form the posted ledger: a
 * reversed journal still counts, and its linked reversal journal cancels it,
 * so past periods remain reproducible. {@code pending} journals only affect
 * the pending view and {@code draft} journals affect nothing.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum JournalStatus {
    DRAFT,
    PENDING,
    POSTED,
    REVERSED;

    /** Returns the wire name, for example {@code posted}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire wire name
     * @return the status
     * @throws IllegalArgumentException when unknown
     */
    public static JournalStatus fromWire(String wire) {
        return WireNames.lookup(JournalStatus.class, wire, JournalStatus::wire);
    }

    public boolean inPostedLedger() {
        return this == POSTED || this == REVERSED;
    }
}
