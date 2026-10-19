package com.paulsnow.finance.core.ledger;

import java.util.Objects;

/**
 * One line of a journal. Debits are positive, credits negative.
 *
 * @param ledgerAccountId user account, category or {@code system:} account identifier
 * @param amountMinor     signed amount in minor units
 * @param currency        ISO 4217 currency code
 * @author Paul Snow
 * @since 0.0.0
 */
public record Posting(String ledgerAccountId, long amountMinor, String currency) {

    public Posting {
        Objects.requireNonNull(ledgerAccountId, "ledgerAccountId");
        Objects.requireNonNull(currency, "currency");
    }

    /** Returns this posting with its amount negated. */
    public Posting negated() {
        return new Posting(ledgerAccountId, -amountMinor, currency);
    }
}
