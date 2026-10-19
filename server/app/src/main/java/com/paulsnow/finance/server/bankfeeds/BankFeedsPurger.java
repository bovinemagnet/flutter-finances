package com.paulsnow.finance.server.bankfeeds;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Erases a deleted workspace's bank feeds: consent is withdrawn at each
 * provider (best effort), then connections, tokens, accounts and provider
 * records are deleted.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class BankFeedsPurger implements WorkspaceDataPurger {

    private final BankFeedService service;
    private final ConnectionStore store;

    BankFeedsPurger(BankFeedService service, ConnectionStore store) {
        this.service = service;
        this.store = store;
    }

    @Override
    public String step() {
        return "bankfeeds";
    }

    @Override
    public long purge(UUID workspaceId) {
        store.list(workspaceId).stream().filter(c -> !"revoked".equals(c.consentStatus()))
                .forEach(service::revokeAtProvider);
        return store.purgeWorkspace(workspaceId);
    }
}
