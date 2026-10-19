package com.paulsnow.finance.server.receipts;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes receipt document records of a deleted workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ReceiptsPurger implements WorkspaceDataPurger {

    private final ReceiptService receipts;

    ReceiptsPurger(ReceiptService receipts) {
        this.receipts = receipts;
    }

    @Override
    public String step() {
        return "receipts";
    }

    @Override
    public long purge(UUID workspaceId) {
        return receipts.purgeWorkspace(workspaceId);
    }
}
