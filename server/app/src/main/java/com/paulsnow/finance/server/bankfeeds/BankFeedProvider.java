package com.paulsnow.finance.server.bankfeeds;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * The boundary to one bank data provider (BANK 03), for example an
 * Australian Consumer Data Right intermediary. Adapters run on the server
 * only: provider tokens never reach clients, and the application never asks
 * users for bank passwords; consent is given at the provider or data
 * holder through the URL {@link #startConsent} returns. What an adapter
 * returns becomes provider records, kept apart from canonical journals.
 * Adapters are beans; the {@code sandbox} adapter exists only when
 * {@code finance.bank-feeds.sandbox.enabled} is true.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface BankFeedProvider {

    /** Returns the stable provider identifier used in API paths and records, for example {@code sandbox}. */
    String id();

    /**
     * Starts consent for a new connection or a reconnect. A real provider
     * returns a URL the user opens to consent at the provider; a sandbox may
     * grant at once.
     *
     * @param request what the user is asked to share and why
     * @return a redirect or an immediate grant
     */
    ConsentStart startConsent(ConsentRequest request);

    /**
     * Completes a redirect consent with the code the provider returned.
     *
     * @param state the state the server put in the consent URL
     * @param code  the provider's authorisation code
     * @return the grant
     * @throws ConsentRejectedException when the provider refuses the code
     */
    ProviderGrant completeConsent(String state, String code);

    /**
     * Lists the accounts the consent shares.
     *
     * @param tokens current tokens
     * @return shared accounts
     */
    List<ProviderAccount> listAccounts(ProviderTokens tokens);

    /**
     * Fetches an account's transactions after a cursor.
     *
     * @param tokens    current tokens
     * @param accountId provider account identifier
     * @param cursor    the previous page's {@code nextCursor}, or null for a backfill
     * @return one page
     * @throws RateLimitedException    when the provider asks the caller to slow down
     * @throws ConsentExpiredException when the consent no longer allows collection
     */
    TransactionPage fetchTransactions(ProviderTokens tokens, String accountId, String cursor);

    /**
     * Returns the consent's status at the provider.
     *
     * @param tokens current tokens
     * @return status and expiry
     */
    ConsentStatus consentStatus(ProviderTokens tokens);

    /**
     * Exchanges the refresh token for new tokens.
     *
     * @param tokens current tokens
     * @return new tokens
     * @throws ConsentExpiredException when the consent has ended
     */
    ProviderTokens refresh(ProviderTokens tokens);

    /**
     * Withdraws the consent at the provider.
     *
     * @param tokens current tokens
     */
    void revoke(ProviderTokens tokens);

    /**
     * What a user is asked to share.
     *
     * @param connectionId        server connection identifier
     * @param institutionId       chosen institution, or null to choose at the provider
     * @param dataScope           data clusters requested
     * @param purpose             why the data is collected, as shown to the user
     * @param state               opaque value the provider must return with the code
     * @param existingReference   the provider's connection reference on reconnect, or null
     */
    record ConsentRequest(UUID connectionId, String institutionId, List<String> dataScope, String purpose,
            String state, String existingReference) {
    }

    /**
     * Either a URL to send the user to, or an immediate grant.
     *
     * @param redirectUrl consent URL at the provider, or null
     * @param grant       immediate grant, or null
     */
    record ConsentStart(String redirectUrl, ProviderGrant grant) {

        public static ConsentStart redirect(String url) {
            return new ConsentStart(url, null);
        }

        public static ConsentStart granted(ProviderGrant grant) {
            return new ConsentStart(null, grant);
        }
    }

    /**
     * A granted consent.
     *
     * @param reference        the provider's identifier of the connection, used by webhooks
     * @param institutionId    institution identifier
     * @param institutionName  institution name shown to the user
     * @param tokens           provider tokens, stored encrypted on the server only
     * @param consentExpiresAt when the consent ends, or null
     */
    record ProviderGrant(String reference, String institutionId, String institutionName, ProviderTokens tokens,
            Instant consentExpiresAt) {
    }

    /**
     * Provider credentials for one connection. Never logged or returned.
     *
     * @param accessToken     access token
     * @param refreshToken    refresh token, or null
     * @param accessExpiresAt when the access token expires, or null
     */
    record ProviderTokens(String accessToken, String refreshToken, Instant accessExpiresAt) {

        @Override
        public String toString() {
            return "ProviderTokens[redacted]";
        }
    }

    /**
     * A shared account.
     *
     * @param id           provider account identifier
     * @param name         display name
     * @param type         for example {@code transaction} or {@code credit_card}
     * @param maskedNumber masked account number, or null
     */
    record ProviderAccount(String id, String name, String type, String maskedNumber) {
    }

    /**
     * One transaction as the provider reports it.
     *
     * @param id                   provider transaction identifier
     * @param accountId            provider account identifier
     * @param status               {@code pending} or {@code posted}
     * @param amountMinor          signed amount in minor units; negative is money out
     * @param currency             ISO 4217 code
     * @param date                 posting date, or the transaction date while pending
     * @param description          provider description (untrusted text)
     * @param pendingId            for a posted transaction, the pending transaction it settles, or null
     * @param previousId           the identifier this transaction had before the provider changed it, or null
     * @param reversalOf           for a reversal, the transaction it reverses, or null
     */
    record ProviderTransaction(String id, String accountId, String status, long amountMinor, String currency,
            LocalDate date, String description, String pendingId, String previousId, String reversalOf) {
    }

    /**
     * One page of transactions.
     *
     * @param transactions transactions in provider order
     * @param nextCursor   cursor for the next fetch; kept even when nothing is new
     * @param hasMore      whether another page is available now
     */
    record TransactionPage(List<ProviderTransaction> transactions, String nextCursor, boolean hasMore) {
    }

    /**
     * Consent status at the provider.
     *
     * @param status    {@code active}, {@code expired} or {@code revoked}
     * @param expiresAt when the consent ends, or null
     */
    record ConsentStatus(String status, Instant expiresAt) {
    }

    /** The provider asked the caller to slow down. */
    class RateLimitedException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        private final transient Duration retryAfter;

        public RateLimitedException(Duration retryAfter) {
            super("RATE_LIMITED");
            this.retryAfter = retryAfter == null ? Duration.ZERO : retryAfter;
        }

        public Duration retryAfter() {
            return retryAfter;
        }
    }

    /** The consent has expired or was withdrawn at the provider. */
    class ConsentExpiredException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        public ConsentExpiredException() {
            super("CONSENT_EXPIRED");
        }
    }

    /** The provider refused to complete a consent. */
    class ConsentRejectedException extends RuntimeException {

        private static final long serialVersionUID = 1L;

        public ConsentRejectedException() {
            super("CONSENT_REJECTED");
        }
    }
}
