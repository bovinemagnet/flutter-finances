package com.paulsnow.finance.server.deletion;

import java.util.UUID;

/**
 * Erases one module's rows for a deleted workspace. Each module that stores
 * workspace data provides one; the deletion job runs each in its own
 * transaction and records the step, so a failed deletion resumes where it
 * stopped. Implementations must be idempotent.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface WorkspaceDataPurger {

    /** Returns the step name recorded in the deletion status, for example {@code ledger}. */
    String step();

    /** Returns the order in which steps run; lower runs first. */
    default int order() {
        return 100;
    }

    /**
     * Removes the module's data for a workspace.
     *
     * @param workspaceId workspace being deleted
     * @return rows removed, for the deletion record
     */
    long purge(UUID workspaceId);
}
