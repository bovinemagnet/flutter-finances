package com.paulsnow.finance.core.ledger;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Set;

import com.paulsnow.finance.core.money.Money;

/**
 * A user's entry before it becomes a balanced journal (FIN 03).
 * <p>
 * {@code amount} is always a positive magnitude, except for adjustments and
 * opening balances, where it is the signed change or balance from the user's
 * point of view (money held for assets, money owed for liabilities).
 *
 * @param type             what the user entered
 * @param accountId        the account the entry is made against
 * @param amount           amount, see above
 * @param effectiveDate    local financial date
 * @param counterAccountId transfer destination, or null
 * @param splits           category lines for categorised entries
 * @param status           resulting journal status
 * @param payee            payee, or null
 * @param notes            notes, or null
 * @param tags             tags
 * @param refundOf         journal being refunded, or null
 * @param id               journal identifier to use, or null to generate one
 * @param enteredAt        entry instant, or null for now
 * @author Paul Snow
 * @since 0.0.0
 */
public record TransactionDraft(TransactionType type, String accountId, Money amount, LocalDate effectiveDate,
        String counterAccountId, List<Split> splits, JournalStatus status, String payee, String notes,
        Set<String> tags, String refundOf, String id, Instant enteredAt) {

    public TransactionDraft {
        splits = splits == null ? List.of() : List.copyOf(splits);
        tags = tags == null ? Set.of() : Set.copyOf(tags);
        status = status == null ? JournalStatus.POSTED : status;
    }

    /**
     * Starts a posted draft.
     *
     * @param type          entry type
     * @param accountId     account
     * @param amount        amount
     * @param effectiveDate local date
     * @return a builder
     */
    public static Builder builder(TransactionType type, String accountId, Money amount, LocalDate effectiveDate) {
        return new Builder(type, accountId, amount, effectiveDate);
    }

    /**
     * Builder for {@link TransactionDraft}.
     *
     * @author Paul Snow
     * @since 0.0.0
     */
    public static final class Builder {
        private final TransactionType type;
        private final String accountId;
        private final Money amount;
        private final LocalDate effectiveDate;
        private String counterAccountId;
        private List<Split> splits = List.of();
        private JournalStatus status = JournalStatus.POSTED;
        private String payee;
        private String notes;
        private Set<String> tags = Set.of();
        private String refundOf;
        private String id;
        private Instant enteredAt;

        private Builder(TransactionType type, String accountId, Money amount, LocalDate effectiveDate) {
            this.type = type;
            this.accountId = accountId;
            this.amount = amount;
            this.effectiveDate = effectiveDate;
        }

        public Builder counterAccountId(String value) {
            this.counterAccountId = value;
            return this;
        }

        public Builder splits(List<Split> value) {
            this.splits = value;
            return this;
        }

        public Builder status(JournalStatus value) {
            this.status = value;
            return this;
        }

        public Builder payee(String value) {
            this.payee = value;
            return this;
        }

        public Builder notes(String value) {
            this.notes = value;
            return this;
        }

        public Builder tags(Set<String> value) {
            this.tags = value;
            return this;
        }

        public Builder refundOf(String value) {
            this.refundOf = value;
            return this;
        }

        public Builder id(String value) {
            this.id = value;
            return this;
        }

        public Builder enteredAt(Instant value) {
            this.enteredAt = value;
            return this;
        }

        public TransactionDraft build() {
            return new TransactionDraft(type, accountId, amount, effectiveDate, counterAccountId, splits, status,
                    payee, notes, tags, refundOf, id, enteredAt);
        }
    }
}
