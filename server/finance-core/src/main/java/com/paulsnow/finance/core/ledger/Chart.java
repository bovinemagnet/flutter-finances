package com.paulsnow.finance.core.ledger;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;

import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;

/**
 * The user's accounts and categories, mapped onto ledger accounts. A user
 * account's ledger account shares its identifier, as does each category, so
 * postings reference user-facing identifiers directly.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Chart {

    private final CurrencyUnit currency;
    private final Map<String, Account> accounts = new LinkedHashMap<>();
    private final Map<String, Category> categories = new LinkedHashMap<>();

    /**
     * Creates a chart.
     *
     * @param currency   the workspace currency
     * @param accounts   user accounts
     * @param categories categories
     */
    public Chart(CurrencyUnit currency, Collection<Account> accounts, Collection<Category> categories) {
        this.currency = currency;
        accounts.forEach(a -> this.accounts.put(a.id(), a));
        categories.forEach(c -> this.categories.put(c.id(), c));
    }

    public CurrencyUnit currency() {
        return currency;
    }

    public Collection<Account> accounts() {
        return accounts.values();
    }

    public Collection<Category> categories() {
        return categories.values();
    }

    public boolean hasAccount(String id) {
        return id != null && accounts.containsKey(id);
    }

    public boolean hasCategory(String id) {
        return id != null && categories.containsKey(id);
    }

    public Account account(String id) {
        Account account = accounts.get(id);
        if (account == null) {
            throw new IllegalArgumentException("Unknown account");
        }
        return account;
    }

    public Category category(String id) {
        Category category = categories.get(id);
        if (category == null) {
            throw new IllegalArgumentException("Unknown category");
        }
        return category;
    }

    /**
     * Returns the ledger kind of any posting target.
     *
     * @param ledgerAccountId posting target
     * @return the kind, or null when the target is unknown
     */
    public LedgerKind kindOf(String ledgerAccountId) {
        Account account = accounts.get(ledgerAccountId);
        if (account != null) {
            return account.type().ledgerKind();
        }
        Category category = categories.get(ledgerAccountId);
        if (category != null) {
            return category.kind().ledgerKind();
        }
        return SystemAccounts.KINDS.get(ledgerAccountId);
    }

    /**
     * Converts a user-facing signed amount into a ledger delta for
     * {@code kind}. For assets a positive amount is money held; for
     * liabilities it is money owed, which the ledger records as a credit.
     *
     * @param kind       ledger kind of the account
     * @param userAmount amount as the user reads it
     * @return the ledger delta
     */
    public static Money toLedgerSign(LedgerKind kind, Money userAmount) {
        return kind == LedgerKind.LIABILITY ? userAmount.negate() : userAmount;
    }
}
