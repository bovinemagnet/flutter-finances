package com.paulsnow.finance.server.exports;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes export records of a deleted workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ExportsPurger implements WorkspaceDataPurger {

    private final ExportService exports;

    ExportsPurger(ExportService exports) {
        this.exports = exports;
    }

    @Override
    public String step() {
        return "exports";
    }

    @Override
    public long purge(UUID workspaceId) {
        return exports.purgeWorkspace(workspaceId);
    }
}
