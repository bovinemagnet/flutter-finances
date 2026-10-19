package com.paulsnow.finance.core.ledger;

import java.util.ArrayList;
import java.util.List;

import com.paulsnow.finance.core.money.Money;

/**
 * Checks that postings form a valid balanced journal in one currency.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class JournalValidator {

    private JournalValidator() {
    }

    /**
     * Validates postings and returns every applicable error code.
     * <ul>
     * <li>A posting beyond the maximum magnitude cannot be represented as
     * money, so only {@code OUT_OF_RANGE} is reported (as the Dart client
     * does when constructing the amount fails).</li>
     * <li>{@code EMPTY} is reported alone.</li>
     * <li>{@code MIXED_CURRENCY} stops further checks.</li>
     * <li>The journal is out of range when its total debits exceed the
     * maximum magnitude, which keeps the check independent of posting
     * order.</li>
     * </ul>
     *
     * @param postings the journal's postings
     * @return error codes, empty when valid
     */
    public static List<LedgerError> validate(List<Posting> postings) {
        if (postings.stream().anyMatch(p -> !Money.inRange(p.amountMinor()))) {
            return List.of(LedgerError.OUT_OF_RANGE);
        }
        if (postings.isEmpty()) {
            return List.of(LedgerError.EMPTY);
        }
        List<LedgerError> errors = new ArrayList<>();
        if (postings.size() < 2) {
            errors.add(LedgerError.TOO_FEW_POSTINGS);
        }
        String currency = postings.getFirst().currency();
        if (postings.stream().anyMatch(p -> !p.currency().equals(currency))) {
            errors.add(LedgerError.MIXED_CURRENCY);
            return List.copyOf(errors);
        }
        long net = 0;
        long debits = 0;
        for (Posting posting : postings) {
            net += posting.amountMinor();
            if (posting.amountMinor() > 0) {
                debits += posting.amountMinor();
            }
        }
        if (net != 0) {
            errors.add(LedgerError.UNBALANCED);
        }
        if (postings.stream().anyMatch(p -> p.amountMinor() == 0)) {
            errors.add(LedgerError.ZERO_AMOUNT);
        }
        if (debits > Money.MAX_MINOR_MAGNITUDE) {
            errors.add(LedgerError.OUT_OF_RANGE);
        }
        return List.copyOf(errors);
    }
}
