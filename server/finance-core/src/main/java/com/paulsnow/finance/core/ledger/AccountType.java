package com.paulsnow.finance.core.ledger;

/**
 * What a user calls an account (FIN 01).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum AccountType {
    TRANSACTION,
    SAVINGS,
    CASH,
    CREDIT_CARD,
    LOAN,
    PROPERTY,
    INVESTMENT,
    SUPERANNUATION,
    OTHER_ASSET;

    /** Returns the camelCase name used in JSON, for example {@code creditCard}. */
    public String wire() {
        return WireNames.camel(this);
    }

    /**
     * Resolves a wire name.
     *
     * @param wire camelCase name
     * @return the account type
     * @throws IllegalArgumentException when unknown
     */
    public static AccountType fromWire(String wire) {
        return WireNames.lookup(AccountType.class, wire, AccountType::wire);
    }

    public boolean isLiability() {
        return this == CREDIT_CARD || this == LOAN;
    }

    /** Money that can be spent without selling or redeeming anything. */
    public boolean isLiquid() {
        return this == TRANSACTION || this == SAVINGS || this == CASH;
    }

    public LedgerKind ledgerKind() {
        return isLiability() ? LedgerKind.LIABILITY : LedgerKind.ASSET;
    }
}
