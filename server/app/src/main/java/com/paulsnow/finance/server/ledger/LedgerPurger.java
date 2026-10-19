package com.paulsnow.finance.server.ledger;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes journals and postings of a deleted workspace, bypassing the
 * posted-journal immutability trigger for that transaction only.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class LedgerPurger implements WorkspaceDataPurger {

    private final LedgerService ledger;

    LedgerPurger(LedgerService ledger) {
        this.ledger = ledger;
    }

    @Override
    public String step() {
        return "ledger";
    }

    @Override
    public long purge(UUID workspaceId) {
        return ledger.purgeWorkspace(workspaceId);
    }
}
