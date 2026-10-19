package com.paulsnow.finance.core.ledger;

import java.util.Map;

/**
 * Ledger accounts the application maintains on the user's behalf. Their
 * identifiers are fixed so every device agrees on them without syncing.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class SystemAccounts {

    /** Prefix shared by every system ledger account identifier. */
    public static final String PREFIX = "system:";

    public static final String OPENING_EQUITY = "system:opening-equity";
    public static final String BALANCE_ADJUSTMENTS = "system:balance-adjustments";
    public static final String TRANSFER_CLEARING = "system:transfer-clearing";
    public static final String REIMBURSEMENT_RECEIVABLE = "system:reimbursement-receivable";

    /** Ledger kind of each known system account. */
    public static final Map<String, LedgerKind> KINDS = Map.of(
            OPENING_EQUITY, LedgerKind.EQUITY,
            BALANCE_ADJUSTMENTS, LedgerKind.EQUITY,
            TRANSFER_CLEARING, LedgerKind.ASSET,
            REIMBURSEMENT_RECEIVABLE, LedgerKind.ASSET);

    private SystemAccounts() {
    }

    /**
     * Returns whether {@code ledgerAccountId} names a system account.
     *
     * @param ledgerAccountId posting target
     * @return true for {@code system:} identifiers
     */
    public static boolean isSystem(String ledgerAccountId) {
        return ledgerAccountId != null && ledgerAccountId.startsWith(PREFIX);
    }
}
