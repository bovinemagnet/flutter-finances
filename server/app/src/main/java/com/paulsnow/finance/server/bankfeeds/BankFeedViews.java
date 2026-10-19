package com.paulsnow.finance.server.bankfeeds;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * Request and response bodies of the bank feed API. Provider tokens never
 * appear in any of them.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
final class BankFeedViews {

    private BankFeedViews() {
    }

    /**
     * Starts a connection.
     *
     * @param provider      provider identifier, for example {@code sandbox}
     * @param institutionId institution to connect, or null to choose at the provider
     * @param dataScope     data clusters to request; defaults to account basics and transactions
     * @param purpose       why the data is collected, shown with the consent
     */
    record CreateRequest(String provider, String institutionId, List<String> dataScope, String purpose) {
    }

    /**
     * Completes a redirect consent.
     *
     * @param state the {@code state} from the consent URL
     * @param code  the provider's authorisation code
     */
    record CallbackRequest(String state, String code) {
    }

    /**
     * A decision on a proposal.
     *
     * @param decision  {@code accepted} or {@code dismissed}
     * @param journalId the journal the client posted for an accepted proposal, or null
     */
    record DecisionRequest(String decision, UUID journalId) {
    }

    /** Institution of a connection. */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    record Institution(String id, String name) {
    }

    /** A shared account. */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    record SharedAccount(String id, String name, String type, String maskedNumber) {
    }

    /** The feed's error state. */
    record ErrorState(String code, Instant at) {
    }

    /** A connection as members see it (BANK 02). */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    record ConnectionView(UUID id, String provider, Institution institution, List<SharedAccount> sharedAccounts,
            List<String> dataScope, String purpose, String consentStatus, Instant consentExpiresAt,
            Instant lastSuccessfulRefreshAt, boolean stale, ErrorState error, Instant nextRefreshAt,
            Instant createdAt, Instant revokedAt, String consentUrl) {
    }

    /** A queued refresh. */
    record RefreshResponse(UUID jobId) {
    }

    /** A connection's proposals. */
    record ProposalsResponse(UUID connectionId, List<RecordReconciler.Proposal> proposals) {
    }

    /** A webhook outcome: {@code accepted} or {@code duplicate}. */
    record WebhookResponse(String status) {
    }
}
