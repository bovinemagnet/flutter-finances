package com.paulsnow.finance.server.inboundmail;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;
import com.paulsnow.finance.server.storage.ObjectStorage;

/**
 * Removes a deleted workspace's addresses, messages and documents.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundMailPurger implements WorkspaceDataPurger {

    private final InboundAddressStore addresses;
    private final InboundMessageStore messages;
    private final ObjectStorage storage;

    InboundMailPurger(InboundAddressStore addresses, InboundMessageStore messages, ObjectStorage storage) {
        this.addresses = addresses;
        this.messages = messages;
        this.storage = storage;
    }

    @Override
    public String step() {
        return "inboundmail";
    }

    @Override
    public long purge(UUID workspaceId) {
        long objects = storage.deletePrefix("inbound-mail/" + workspaceId + "/");
        return objects + messages.purgeWorkspace(workspaceId) + addresses.purgeWorkspace(workspaceId);
    }
}
