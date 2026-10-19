package com.paulsnow.finance.server.bankfeeds;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ConsentStatus;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderTokens;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.TransactionPage;
import com.paulsnow.finance.server.bankfeeds.ConnectionStore.Connection;
import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Collects new transactions for one connection ({@code bankfeeds.refresh}):
 * renews the access token when due, confirms the consent is still active,
 * refreshes the shared accounts, then pages each account from its stored
 * cursor. The first run is the backfill. A rate limit is not an error the
 * job framework retries blindly: the handler records it, waits the base
 * delay doubled for each consecutive limit (at least what the provider
 * asked, at most the configured maximum) and queues its own retry.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class RefreshJobHandler implements JobHandler {

    private static final Logger LOG = LoggerFactory.getLogger(RefreshJobHandler.class);
    private static final Duration TOKEN_MARGIN = Duration.ofMinutes(1);
    private static final int MAX_PAGES = 1000;

    private final BankFeedService service;
    private final ConnectionStore store;
    private final RecordReconciler reconciler;
    private final BankFeedProperties properties;
    private final Clock clock;

    RefreshJobHandler(BankFeedService service, ConnectionStore store, RecordReconciler reconciler,
            BankFeedProperties properties, Clock clock) {
        this.service = service;
        this.store = store;
        this.reconciler = reconciler;
        this.properties = properties;
        this.clock = clock;
    }

    @Override
    public String type() {
        return BankFeedService.REFRESH_JOB;
    }

    @Override
    public JsonNode handle(Job job) {
        UUID id = UUID.fromString(job.payload().path("connectionId").asString());
        ObjectNode result = JsonNodeFactory.instance.objectNode().put("connectionId", id.toString());
        Optional<Connection> found = store.findAny(id).filter(c -> c.workspaceId().equals(job.workspaceId()));
        if (found.isEmpty() || !found.get().collecting()) {
            return result.put("status", "skipped");
        }
        Connection connection = found.get();
        Optional<BankFeedProvider> provider = service.provider(connection.provider());
        Optional<ProviderTokens> stored = store.tokens(id);
        if (provider.isEmpty() || stored.isEmpty()) {
            store.markError(id, provider.isEmpty() ? "PROVIDER_UNAVAILABLE" : "TOKENS_MISSING",
                    connection.rateLimitAttempts(), null);
            return result.put("status", "skipped");
        }
        try {
            ProviderTokens tokens = stored.get();
            if (tokens.accessExpiresAt() != null
                    && !clock.instant().isBefore(tokens.accessExpiresAt().minus(TOKEN_MARGIN))) {
                tokens = provider.get().refresh(tokens);
                store.saveTokens(id, connection.workspaceId(), tokens);
            }
            ConsentStatus consent = provider.get().consentStatus(tokens);
            if ("revoked".equals(consent.status())) {
                store.revoke(id);
                return result.put("status", "consent_revoked");
            }
            if (!"active".equals(consent.status())) {
                store.expire(id, consent.expiresAt());
                return result.put("status", "consent_expired");
            }
            store.markConsent(id, "active", consent.expiresAt());
            store.saveAccounts(id, connection.workspaceId(), provider.get().listAccounts(tokens));
            int transactions = 0;
            for (ConnectionStore.Account account : store.accounts(id)) {
                String cursor = account.cursor();
                for (int page = 0; page < MAX_PAGES; page++) {
                    TransactionPage fetched = provider.get().fetchTransactions(tokens, account.id(), cursor);
                    if (!reconciler.applyPage(connection, account.id(), fetched.transactions(),
                            fetched.nextCursor())) {
                        return result.put("status", "stopped");
                    }
                    transactions += fetched.transactions().size();
                    cursor = fetched.nextCursor();
                    if (!fetched.hasMore()) {
                        break;
                    }
                }
            }
            store.markSucceeded(id);
            return result.put("status", "refreshed").put("transactions", transactions);
        } catch (BankFeedProvider.RateLimitedException e) {
            return rateLimited(connection, e.retryAfter(), result);
        } catch (BankFeedProvider.ConsentExpiredException e) {
            store.expire(id, null);
            return result.put("status", "consent_expired");
        } catch (RuntimeException e) {
            LOG.warn("Bank feed refresh failed for connection {}: {}", id, e.getClass().getSimpleName());
            store.markError(id, "PROVIDER_ERROR", connection.rateLimitAttempts(), null);
            throw e;
        }
    }

    private JsonNode rateLimited(Connection connection, Duration retryAfter, ObjectNode result) {
        int attempts = connection.rateLimitAttempts() + 1;
        if (attempts > properties.maxRateLimitRetries()) {
            store.markError(connection.id(), "RATE_LIMITED", attempts, null);
            return result.put("status", "rate_limited");
        }
        Instant next = clock.instant().plus(properties.backoff(attempts, retryAfter));
        store.markError(connection.id(), "RATE_LIMITED", attempts, next);
        service.enqueueRefreshAt(connection.workspaceId(), connection.id(), next);
        return result.put("status", "rate_limited").put("retryAt", next.toString());
    }
}
