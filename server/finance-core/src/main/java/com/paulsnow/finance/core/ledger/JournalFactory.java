package com.paulsnow.finance.core.ledger;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import java.util.function.Supplier;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.core.money.Money;

/**
 * Turns user entries into balanced journals without exposing accounting
 * terminology to the interface. Validation order matches
 * {@code spec/fixtures/README.md} and reports the first failure.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class JournalFactory {

    private final Chart chart;

    public JournalFactory(Chart chart) {
        this.chart = chart;
    }

    /**
     * Builds a balanced journal for {@code draft}.
     *
     * @param draft the user's entry
     * @return the journal
     * @throws DraftException with the first failing rule
     */
    public Journal build(TransactionDraft draft) {
        require(chart.hasAccount(draft.accountId()), DraftError.UNKNOWN_ACCOUNT);
        require(draft.amount().currency().equals(chart.currency()), DraftError.CURRENCY_MISMATCH);
        require(draft.status() != JournalStatus.REVERSED, DraftError.INVALID_STATUS);
        String account = draft.accountId();
        Money amount = draft.amount();
        List<Posting> postings = switch (draft.type()) {
            case EXPENSE -> categorised(draft, CategoryKind.EXPENSE, a -> List.of(posting(account, a.negate())), 1);
            case INCOME -> categorised(draft, CategoryKind.INCOME, a -> List.of(posting(account, a)), -1);
            case REFUND -> categorised(draft, CategoryKind.EXPENSE, a -> List.of(posting(account, a)), -1);
            case TRANSFER -> transfer(draft);
            case OPENING_BALANCE -> againstSystem(draft, SystemAccounts.OPENING_EQUITY);
            case ADJUSTMENT -> againstSystem(draft, SystemAccounts.BALANCE_ADJUSTMENTS);
            case REIMBURSABLE_EXPENSE -> positive(draft, () -> List.of(
                    posting(SystemAccounts.REIMBURSEMENT_RECEIVABLE, amount),
                    posting(account, amount.negate())));
            case REIMBURSEMENT -> draft.splits().isEmpty()
                    ? positive(draft, () -> List.of(
                            posting(account, amount),
                            posting(SystemAccounts.REIMBURSEMENT_RECEIVABLE, amount.negate())))
                    : categorised(draft, CategoryKind.EXPENSE, a -> List.of(posting(account, a)), -1);
            case REVERSAL -> throw new IllegalArgumentException("Use Corrections to create reversals");
        };
        return new Journal(draft.id() != null ? draft.id() : Ids.newId(), draft.type(), draft.status(),
                draft.effectiveDate(), draft.enteredAt() != null ? draft.enteredAt() : Instant.now(),
                chart.currency(), postings, draft.accountId(), draft.counterAccountId(), amount, draft.payee(),
                draft.notes(), draft.tags(), draft.refundOf(), null, null);
    }

    private List<Posting> categorised(TransactionDraft draft, CategoryKind kind,
            Function<Money, List<Posting>> accountSide, int sign) {
        return positive(draft, () -> {
            require(!draft.splits().isEmpty(), DraftError.MISSING_SPLITS);
            Money total = Money.zero(chart.currency());
            List<Posting> postings = new ArrayList<>();
            for (Split split : draft.splits()) {
                require(chart.hasCategory(split.categoryId()), DraftError.UNKNOWN_CATEGORY);
                require(chart.category(split.categoryId()).kind() == kind, DraftError.WRONG_CATEGORY_KIND);
                require(split.amount().isPositive(), DraftError.NON_POSITIVE_AMOUNT);
                total = total.plus(split.amount());
                postings.add(posting(split.categoryId(), sign > 0 ? split.amount() : split.amount().negate()));
            }
            require(total.equals(draft.amount()), DraftError.SPLIT_MISMATCH);
            postings.addAll(accountSide.apply(draft.amount()));
            return postings;
        });
    }

    private List<Posting> transfer(TransactionDraft draft) {
        String to = draft.counterAccountId();
        require(chart.hasAccount(to), DraftError.UNKNOWN_ACCOUNT);
        require(!to.equals(draft.accountId()), DraftError.SAME_ACCOUNT);
        return positive(draft, () -> List.of(
                posting(to, draft.amount()),
                posting(draft.accountId(), draft.amount().negate())));
    }

    private List<Posting> againstSystem(TransactionDraft draft, String systemAccount) {
        require(!draft.amount().isZero(), DraftError.NON_POSITIVE_AMOUNT);
        LedgerKind kind = chart.account(draft.accountId()).type().ledgerKind();
        Money delta = Chart.toLedgerSign(kind, draft.amount());
        return List.of(posting(draft.accountId(), delta), posting(systemAccount, delta.negate()));
    }

    private static List<Posting> positive(TransactionDraft draft, Supplier<List<Posting>> build) {
        require(draft.amount().isPositive(), DraftError.NON_POSITIVE_AMOUNT);
        return build.get();
    }

    private Posting posting(String ledgerAccountId, Money amount) {
        return new Posting(ledgerAccountId, amount.minor(), chart.currency().code());
    }

    private static void require(boolean condition, DraftError error) {
        if (!condition) {
            throw new DraftException(error);
        }
    }
}
