package com.paulsnow.finance.server.bankfeeds;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ConsentRequest;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ConsentStart;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderGrant;
import com.paulsnow.finance.server.bankfeeds.BankFeedViews.ConnectionView;
import com.paulsnow.finance.server.bankfeeds.ConnectionStore.Connection;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.workspace.CurrentMember;

import tools.jackson.databind.node.JsonNodeFactory;

/**
 * The connection lifecycle (BANK 02): connect, complete a redirect
 * consent, refresh, reconnect and revoke. Provider calls run outside
 * database transactions; each state change is one short transaction.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class BankFeedService {

    /** Job type of a refresh (backfill when no cursor is stored yet). */
    static final String REFRESH_JOB = "bankfeeds.refresh";

    /** Data clusters a connection may request; consent covers no more than these. */
    static final List<String> SCOPES = List.of("bank:accounts.basic:read", "bank:transactions:read");

    private static final Logger LOG = LoggerFactory.getLogger(BankFeedService.class);
    private static final int REFRESH_ATTEMPTS = 3;

    private final Map<String, BankFeedProvider> providers;
    private final ConnectionStore store;
    private final TokenCipher cipher;
    private final JobService jobs;
    private final BankFeedProperties properties;
    private final Clock clock;
    private final ApplicationEventPublisher events;
    private final SecureRandom random = new SecureRandom();

    BankFeedService(List<BankFeedProvider> providers, ConnectionStore store, TokenCipher cipher, JobService jobs,
            BankFeedProperties properties, Clock clock, ApplicationEventPublisher events) {
        this.providers = providers.stream().collect(Collectors.toMap(BankFeedProvider::id, Function.identity()));
        this.store = store;
        this.cipher = cipher;
        this.jobs = jobs;
        this.properties = properties;
        this.clock = clock;
        this.events = events;
    }

    Optional<BankFeedProvider> provider(String id) {
        return Optional.ofNullable(providers.get(id));
    }

    boolean hasProvider(String id) {
        return providers.containsKey(id);
    }

    ConnectionView create(CurrentMember member, BankFeedViews.CreateRequest request) {
        member.requireWriter();
        BankFeedProvider provider = provider(request.provider())
                .orElseThrow(() -> ApiException.badRequest("UNKNOWN_PROVIDER", "This provider is not available."));
        if (!cipher.available()) {
            throw ApiException.conflict("BANK_FEEDS_UNAVAILABLE", "Bank feeds are not configured on this service.");
        }
        String purpose = request.purpose() == null ? "" : request.purpose().strip();
        if (purpose.isEmpty() || purpose.length() > 500) {
            throw ApiException.badRequest("PURPOSE_REQUIRED", "State why the data is collected (up to 500 characters).");
        }
        List<String> scope = request.dataScope() == null || request.dataScope().isEmpty() ? SCOPES
                : request.dataScope().stream().distinct().toList();
        if (!SCOPES.containsAll(scope)) {
            throw ApiException.badRequest("INVALID_SCOPE", "Request only " + String.join(", ", SCOPES) + ".");
        }
        UUID id = Ids.newUuid();
        String state = newState();
        store.insertPending(id, member.workspaceId(), provider.id(), request.institutionId(), scope, purpose,
                sha256(state), member.user().id());
        ConsentStart start = provider.startConsent(new ConsentRequest(id, request.institutionId(), scope, purpose,
                state, null));
        events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(), "bank_feed.created", "bank_feed",
                id));
        return begin(member, find(member, id), provider, start, "bank_feed.connected");
    }

    ConnectionView completeConsent(CurrentMember member, UUID id, BankFeedViews.CallbackRequest request) {
        member.requireWriter();
        Connection connection = find(member, id);
        if ("revoked".equals(connection.consentStatus())) {
            throw revoked();
        }
        if (connection.consentStateSha256() == null) {
            throw ApiException.conflict("CONSENT_NOT_PENDING", "No consent is waiting for this connection.");
        }
        String state = request == null || request.state() == null ? "" : request.state();
        if (!MessageDigest.isEqual(sha256(state).getBytes(StandardCharsets.US_ASCII),
                connection.consentStateSha256().getBytes(StandardCharsets.US_ASCII))) {
            throw ApiException.badRequest("INVALID_CONSENT_STATE", "The consent state does not match.");
        }
        BankFeedProvider provider = requireProvider(connection);
        ProviderGrant grant;
        try {
            grant = provider.completeConsent(state, request.code());
        } catch (BankFeedProvider.ConsentRejectedException e) {
            throw ApiException.conflict("CONSENT_REJECTED", "The provider did not confirm the consent.");
        }
        activate(member, connection, provider, grant,
                connection.reference() == null ? "bank_feed.connected" : "bank_feed.reconnected");
        return view(find(member, id), null);
    }

    UUID requestRefresh(CurrentMember member, UUID id) {
        member.requireWriter();
        Connection connection = find(member, id);
        switch (connection.consentStatus()) {
            case "revoked" -> throw revoked();
            case "expired" -> throw ApiException.conflict("CONSENT_EXPIRED", "Reconnect to renew the consent.");
            case "pending" -> throw ApiException.conflict("CONSENT_PENDING", "Complete the consent first.");
            default -> {
                return enqueueRefresh(connection.workspaceId(), id);
            }
        }
    }

    ConnectionView reconnect(CurrentMember member, UUID id) {
        member.requireWriter();
        Connection connection = find(member, id);
        if ("revoked".equals(connection.consentStatus())) {
            throw revoked();
        }
        BankFeedProvider provider = requireProvider(connection);
        String state = newState();
        store.beginReconnect(id, sha256(state));
        ConsentStart start = provider.startConsent(new ConsentRequest(id, connection.institutionId(),
                connection.dataScope(), connection.purpose(), state, connection.reference()));
        return begin(member, connection, provider, start, "bank_feed.reconnected");
    }

    /**
     * Revokes a connection: withdraws consent at the provider (best effort),
     * deletes the tokens and stops collection for good.
     */
    ConnectionView revoke(CurrentMember member, UUID id) {
        member.requireWriter();
        Connection connection = find(member, id);
        if (!"revoked".equals(connection.consentStatus())) {
            revokeAtProvider(connection);
            store.revoke(id);
            events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(), "bank_feed.revoked",
                    "bank_feed", id));
        }
        return view(find(member, id), null);
    }

    /** Withdraws consent at the provider without failing when the provider cannot be reached. */
    void revokeAtProvider(Connection connection) {
        provider(connection.provider()).ifPresent(provider -> {
            try {
                store.tokens(connection.id()).ifPresent(provider::revoke);
            } catch (RuntimeException e) {
                LOG.warn("Provider revocation failed for bank feed connection {}; tokens are deleted regardless",
                        connection.id());
            }
        });
    }

    List<ConnectionView> list(CurrentMember member) {
        return store.list(member.workspaceId()).stream().map(c -> view(c, null)).toList();
    }

    ConnectionView get(CurrentMember member, UUID id) {
        return view(find(member, id), null);
    }

    Connection find(CurrentMember member, UUID id) {
        return store.find(member.workspaceId(), id)
                .orElseThrow(() -> ApiException.notFound("CONNECTION_NOT_FOUND", "Connection not found."));
    }

    UUID enqueueRefresh(UUID workspaceId, UUID connectionId) {
        return jobs.enqueue(REFRESH_JOB, workspaceId,
                JsonNodeFactory.instance.objectNode().put("connectionId", connectionId.toString()), REFRESH_ATTEMPTS);
    }

    UUID enqueueRefreshAt(UUID workspaceId, UUID connectionId, Instant runAfter) {
        return jobs.enqueueAt(REFRESH_JOB, workspaceId,
                JsonNodeFactory.instance.objectNode().put("connectionId", connectionId.toString()), REFRESH_ATTEMPTS,
                runAfter);
    }

    private ConnectionView begin(CurrentMember member, Connection connection, BankFeedProvider provider,
            ConsentStart start, String auditKind) {
        if (start.grant() != null) {
            activate(member, connection, provider, start.grant(), auditKind);
            return view(find(member, connection.id()), null);
        }
        return view(find(member, connection.id()), start.redirectUrl());
    }

    private void activate(CurrentMember member, Connection connection, BankFeedProvider provider,
            ProviderGrant grant, String auditKind) {
        store.activate(connection.id(), connection.workspaceId(), grant, provider.listAccounts(grant.tokens()));
        enqueueRefresh(connection.workspaceId(), connection.id());
        events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(), auditKind, "bank_feed",
                connection.id()));
    }

    private BankFeedProvider requireProvider(Connection connection) {
        return provider(connection.provider()).orElseThrow(() -> ApiException.conflict("PROVIDER_UNAVAILABLE",
                "This connection's provider is not available."));
    }

    ConnectionView view(Connection c, String consentUrl) {
        Instant now = clock.instant();
        Instant reference = c.lastRefreshAt() == null ? c.createdAt() : c.lastRefreshAt();
        boolean stale = c.collecting() && reference.plus(properties.staleAfter()).isBefore(now);
        List<BankFeedViews.SharedAccount> accounts = store.accounts(c.id()).stream()
                .map(a -> new BankFeedViews.SharedAccount(a.id(), a.name(), a.type(), a.maskedNumber())).toList();
        return new ConnectionView(c.id(), c.provider(), new BankFeedViews.Institution(c.institutionId(),
                c.institutionName()), accounts, c.dataScope(), c.purpose(), c.consentStatus(), c.consentExpiresAt(),
                c.lastRefreshAt(), stale, c.errorCode() == null ? null : new BankFeedViews.ErrorState(c.errorCode(),
                        c.errorAt()), c.nextRefreshAt(), c.createdAt(), c.revokedAt(), consentUrl);
    }

    private String newState() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    static String sha256(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static ApiException revoked() {
        return ApiException.conflict("CONNECTION_REVOKED", "This connection was revoked; connect again instead.");
    }
}
