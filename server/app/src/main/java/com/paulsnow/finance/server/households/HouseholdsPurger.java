package com.paulsnow.finance.server.households;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes a deleted workspace's invitations.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class HouseholdsPurger implements WorkspaceDataPurger {

    private final InvitationService invitations;

    HouseholdsPurger(InvitationService invitations) {
        this.invitations = invitations;
    }

    @Override
    public String step() {
        return "households";
    }

    @Override
    public long purge(UUID workspaceId) {
        return invitations.purgeWorkspace(workspaceId);
    }
}
