package com.paulsnow.finance.server.extraction;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes a deleted workspace's extraction consent and results.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ExtractionPurger implements WorkspaceDataPurger {

    private final ExtractionService extraction;

    ExtractionPurger(ExtractionService extraction) {
        this.extraction = extraction;
    }

    @Override
    public String step() {
        return "extraction";
    }

    @Override
    public long purge(UUID workspaceId) {
        return extraction.purgeWorkspace(workspaceId);
    }
}
