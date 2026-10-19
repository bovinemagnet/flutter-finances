package com.paulsnow.finance.server.workspace;

import java.util.UUID;

/**
 * The caller acting as a member of one active workspace. Controllers
 * declare it as a parameter; the workspace comes from the
 * {@code X-Workspace-Id} header or, failing that, the caller's
 * {@code X-Device-Id}.
 *
 * @param user      the caller
 * @param workspace the workspace
 * @param role      {@code owner} or {@code member}
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
}
