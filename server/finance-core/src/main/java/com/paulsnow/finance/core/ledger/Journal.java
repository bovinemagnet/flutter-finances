package com.paulsnow.finance.core.ledger;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Objects;
import java.util.Set;

import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.core.money.Money;

/**
 * A journal: a set of postings recorded together, plus the user-facing
 * description of the entry they came from.
 *
 * @param id               identifier (UUIDv7)
 * @param type             what the user entered
 * @param status           lifecycle status
 * @param effectiveDate    local financial date in the workspace timezone
 * @param enteredAt        when the entry was recorded (UTC), distinct from the effective date
 * @param currency         the journal currency
 * @param postings         balanced postings
 * @param accountId        the user account the entry was made against, for listing
 * @param counterAccountId transfer destination, or null
 * @param amount           user-facing magnitude of the entry, or null
 * @param payee            payee text, or null
 * @param notes            notes, or null
 * @param tags             tags
 * @param refundOf         journal this refunds, or null
 * @param reversalOf       journal this reverses, or null
 * @param replaces         journal this replaces in a correction, or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record Journal(String id, TransactionType type, JournalStatus status, LocalDate effectiveDate,
        Instant enteredAt, CurrencyUnit currency, List<Posting> postings, String accountId, String counterAccountId,
        Money amount, String payee, String notes, Set<String> tags, String refundOf, String reversalOf,
        String replaces) {

    public Journal {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(type, "type");
        Objects.requireNonNull(status, "status");
        Objects.requireNonNull(effectiveDate, "effectiveDate");
        Objects.requireNonNull(enteredAt, "enteredAt");
        Objects.requireNonNull(currency, "currency");
        postings = List.copyOf(postings);
        tags = tags == null ? Set.of() : Set.copyOf(tags);
    }

    /**
     * Returns a copy with a different status.
     *
     * @param newStatus the status
     * @return the copy
     */
    public Journal withStatus(JournalStatus newStatus) {
        return new Journal(id, type, newStatus, effectiveDate, enteredAt, currency, postings, accountId,
                counterAccountId, amount, payee, notes, tags, refundOf, reversalOf, replaces);
    }

    /**
     * Sums the postings against one ledger account.
     *
     * @param ledgerAccountId ledger account
     * @return the total, or null when the journal does not touch the account
     */
    public Money amountFor(String ledgerAccountId) {
        Money total = null;
        for (Posting posting : postings) {
            if (posting.ledgerAccountId().equals(ledgerAccountId)) {
                Money amount = new Money(posting.amountMinor(), currency);
                total = total == null ? amount : total.plus(amount);
            }
        }
        return total;
    }
}
