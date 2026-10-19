package com.paulsnow.finance.core.ledger;

/**
 * The accounting nature of a ledger account. Never shown to users.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public enum LedgerKind {
    ASSET,
    LIABILITY,
    EQUITY,
    INCOME,
    EXPENSE
}
