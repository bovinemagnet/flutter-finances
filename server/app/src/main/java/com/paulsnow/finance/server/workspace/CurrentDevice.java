package com.paulsnow.finance.server.workspace;

import java.util.UUID;

/**
 * The caller acting through one registered, unrevoked device
 * ({@code X-Device-Id}). Required by the sync endpoints.
 *
 * @param member   the caller's membership of the device's workspace
 * @param deviceId the device
 * @author Paul Snow
 * @since 0.0.0
 */
public record CurrentDevice(CurrentMember member, UUID deviceId) {

    public UUID workspaceId() {
        return member.workspaceId();
    }
}
