package com.paulsnow.finance.server.workspace;

import java.util.UUID;

/**
 * A member's access to a workspace changed. Published inside the transaction
 * that changes it, so a listener's work commits with the change.
 *
 * @param workspaceId workspace
 * @param userId      member
 * @param newRole     their role now, or null when they were removed
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public record MembershipChanged(UUID workspaceId, UUID userId, String newRole) {
}
