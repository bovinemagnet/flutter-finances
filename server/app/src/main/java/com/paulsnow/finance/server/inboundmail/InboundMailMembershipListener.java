package com.paulsnow.finance.server.inboundmail;

import java.time.Clock;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.workspace.MembershipChanged;

/**
 * A member who is removed, or who becomes a viewer, can no longer collect, so
 * their address stops working and what was waiting for them is deleted. Records
 * go inside the transaction that changes the membership. Objects go after it
 * commits, so a storage outage can never keep a member in a workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundMailMembershipListener {

    private static final Logger LOG = LoggerFactory.getLogger(InboundMailMembershipListener.class);

    private final InboundAddressStore addresses;
    private final InboundMessageStore messages;
    private final ObjectStorage storage;
    private final Clock clock;

    InboundMailMembershipListener(InboundAddressStore addresses, InboundMessageStore messages, ObjectStorage storage,
            Clock clock) {
        this.addresses = addresses;
        this.messages = messages;
        this.storage = storage;
        this.clock = clock;
    }

    @EventListener
    void on(MembershipChanged change) {
        if (change.newRole() == null || "viewer".equals(change.newRole())) {
            addresses.revoke(change.workspaceId(), change.userId(), clock.instant());
            List<String> keys = messages.objectKeysOf(change.workspaceId(), change.userId());
            messages.deleteMember(change.workspaceId(), change.userId());
            afterCommit(() -> keys.forEach(this::deleteQuietly));
        }
    }

    private static void afterCommit(Runnable action) {
        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            action.run();
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                action.run();
            }
        });
    }

    private void deleteQuietly(String key) {
        try {
            storage.delete(key);
        } catch (RuntimeException e) {
            // The object is unreachable without its record, and goes when the workspace does.
            LOG.warn("Could not delete a removed member's inbound document");
        }
    }
}
