package com.paulsnow.finance.server.inboundmail;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.common.TokenCipher;
import com.paulsnow.finance.server.workspace.CurrentMember;

/**
 * Turns a member's private forwarding address on, shows it, replaces it and
 * turns it off. An address belongs to one member of one workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class InboundAddressService {

    /** 128 random bits, at five bits per lower-case base32 character. */
    private static final int TOKEN_CHARACTERS = 26;
    private static final char[] BASE32 = "abcdefghijklmnopqrstuvwxyz234567".toCharArray();

    /** An address as a member sees it. */
    record Shown(String address, Instant createdAt) {
    }

    private final InboundAddressStore store;
    private final List<InboundMailProvider> providers;
    private final InboundMailProperties properties;
    private final TokenCipher cipher;
    private final ApplicationEventPublisher events;
    private final Clock clock;
    private final SecureRandom random = new SecureRandom();

    InboundAddressService(InboundAddressStore store, List<InboundMailProvider> providers,
            InboundMailProperties properties, ApplicationEventPublisher events, Clock clock) {
        this.store = store;
        this.providers = providers;
        this.properties = properties;
        this.cipher = new TokenCipher(properties.tokenKey());
        this.events = events;
        this.clock = clock;
    }

    boolean available() {
        return !providers.isEmpty() && cipher.available() && properties.domain() != null
                && !properties.domain().isBlank();
    }

    Shown show(CurrentMember member) {
        member.requireWriter();
        InboundAddressStore.Stored stored = store.findActive(member.workspaceId(), member.user().id())
                .orElseThrow(() -> ApiException.notFound("NOT_FOUND", "Not found."));
        String token = new String(cipher.decrypt(stored.id(), stored.sealed()), StandardCharsets.UTF_8);
        return new Shown(address(token), stored.createdAt());
    }

    /** Creates the member's address, replacing any it already has. */
    @Transactional
    Shown createOrReplace(CurrentMember member) {
        member.requireWriter();
        if (!available()) {
            throw ApiException.conflict("INBOUND_MAIL_UNAVAILABLE", "Email forwarding is not available.");
        }
        Instant now = clock.instant();
        store.revoke(member.workspaceId(), member.user().id(), now);
        UUID id = UUID.randomUUID();
        String token = newToken();
        store.insert(id, member.workspaceId(), member.user().id(), token,
                cipher.encrypt(id, token.getBytes(StandardCharsets.UTF_8)), now);
        events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(), "inbound_mail.address_changed",
                "inbound_address", id));
        return new Shown(address(token), now);
    }

    @Transactional
    void revoke(CurrentMember member) {
        member.requireWriter();
        if (store.revoke(member.workspaceId(), member.user().id(), clock.instant()) > 0) {
            events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(),
                    "inbound_mail.address_revoked", "workspace", member.workspaceId()));
        }
    }

    private String address(String token) {
        return token + "@" + properties.domain();
    }

    private String newToken() {
        StringBuilder token = new StringBuilder(TOKEN_CHARACTERS);
        for (int i = 0; i < TOKEN_CHARACTERS; i++) {
            token.append(BASE32[random.nextInt(BASE32.length)]);
        }
        return token.toString();
    }
}
