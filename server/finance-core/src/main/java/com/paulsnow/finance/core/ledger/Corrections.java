package com.paulsnow.finance.core.ledger;

import java.time.Instant;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;

import com.paulsnow.finance.core.ids.Ids;

/**
 * Financial corrections as a reversal plus replacement linked to the
 * original (FIN 07). Financial history is never rewritten.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Corrections {

    private Corrections() {
    }

    /**
     * Reverses {@code original} on its own effective date, so the corrected
     * figure applies to the period it always belonged to.
     *
     * @param original  a posted journal
     * @param enteredAt entry instant of the reversal
     * @return the reversal journal
     * @throws IllegalStateException when the original is not posted
     */
    public static Journal reverse(Journal original, Instant enteredAt) {
        if (!original.status().inPostedLedger()) {
            throw new IllegalStateException("Only posted journals need a reversal");
        }
        if (original.status() == JournalStatus.REVERSED) {
            throw new IllegalStateException("Journal is already reversed");
        }
        return new Journal(Ids.newId(), TransactionType.REVERSAL, JournalStatus.POSTED, original.effectiveDate(),
                enteredAt, original.currency(), original.postings().stream().map(Posting::negated).toList(),
                original.accountId(), original.counterAccountId(), original.amount(), original.payee(), null, null,
                null, original.id(), null);
    }

    /**
     * Applies an ordinary edit to a posted journal as reversal plus
     * replacement. Pass a null {@code replacement} to void the journal.
     *
     * @param original    the posted journal
     * @param replacement the corrected journal, or null
     * @return the reversed original, the reversal and the linked replacement
     */
    public static CorrectionResult correct(Journal original, Journal replacement) {
        Journal reversal = reverse(original, Instant.now());
        Journal linked = replacement == null ? null
                : new Journal(replacement.id(), replacement.type(), replacement.status(),
                        replacement.effectiveDate(), replacement.enteredAt(), replacement.currency(),
                        replacement.postings(), replacement.accountId(), replacement.counterAccountId(),
                        replacement.amount(), replacement.payee(), replacement.notes(), replacement.tags(),
                        replacement.refundOf() != null ? replacement.refundOf() : original.refundOf(), null,
                        original.id());
        return new CorrectionResult(original.withStatus(JournalStatus.REVERSED), reversal, linked);
    }

    /**
     * Returns whether {@code reversal} negates {@code original} exactly:
     * same currency and effective date, and postings that cancel per ledger
     * account.
     *
     * @param original the journal being reversed
     * @param reversal the proposed reversal
     * @return true when the reversal is exact
     */
    public static boolean isExactReversal(Journal original, Journal reversal) {
        if (!original.id().equals(reversal.reversalOf()) || !original.currency().equals(reversal.currency())
                || !original.effectiveDate().equals(reversal.effectiveDate())
                || original.postings().size() != reversal.postings().size()) {
            return false;
        }
        return net(original.postings(), 1).equals(net(reversal.postings(), -1));
    }

    private static Map<String, Long> net(Collection<Posting> postings, int sign) {
        Map<String, Long> totals = new HashMap<>();
        for (Posting posting : postings) {
            totals.merge(posting.ledgerAccountId(), sign * posting.amountMinor(), Long::sum);
        }
        return totals;
    }
}
