package com.paulsnow.finance.server.workspace;

import java.util.UUID;

import com.paulsnow.finance.server.common.ApiException;

/**
 * The caller acting as a member of one active workspace. Controllers
 * declare it as a parameter; the workspace comes from the
 * {@code X-Workspace-Id} header or, failing that, the caller's
 * {@code X-Device-Id}.
 *
 * @param user      the caller
 * @param workspace the workspace
 * @param role      {@code owner}, {@code member} or {@code viewer}
 * @author Paul Snow
 * @since 0.0.0
 */
public record CurrentMember(CurrentUser user, WorkspaceInfo workspace, String role) {

    public UUID workspaceId() {
        return workspace.id();
    }

    public boolean isOwner() {
        return "owner".equals(role);
    }

    /** Returns whether the member may only read (the {@code viewer} role). */
    public boolean isViewer() {
        return "viewer".equals(role);
    }

    /**
     * Refuses a change for a read-only member.
     *
     * @throws ApiException 403 {@code READ_ONLY} for a viewer
     */
    public void requireWriter() {
        if (isViewer()) {
            throw ApiException.forbidden("READ_ONLY", "Viewers cannot change the workspace.");
        }
    }

    /**
     * Refuses an action reserved for owners.
     *
     * @throws ApiException 403 {@code OWNER_REQUIRED} for anyone else
     */
    public void requireOwner() {
        if (!isOwner()) {
            throw ApiException.forbidden("OWNER_REQUIRED", "Only an owner can do this.");
        }
    }
}
