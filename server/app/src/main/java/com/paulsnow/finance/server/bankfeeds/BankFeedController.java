package com.paulsnow.finance.server.bankfeeds;

import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.bankfeeds.BankFeedViews.ConnectionView;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Bank feed endpoints (BANK 02, BANK 03), scoped to the caller's
 * workspace; another workspace's connection is {@code 404}. The webhook
 * endpoint is the only one called by providers rather than clients, and is
 * authenticated by its signature instead of a user token.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Bank feeds")
class BankFeedController {

    private final BankFeedService service;
    private final RecordReconciler reconciler;
    private final WebhookReceiver webhooks;

    BankFeedController(BankFeedService service, RecordReconciler reconciler, WebhookReceiver webhooks) {
        this.service = service;
        this.reconciler = reconciler;
        this.webhooks = webhooks;
    }

    @PostMapping("/v1/bank-feeds/connections")
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "Start a connection: a consent URL for real providers, immediate for the sandbox")
    ConnectionView create(CurrentMember member, @RequestBody BankFeedViews.CreateRequest request) {
        if (request == null) {
            throw ApiException.badRequest("INVALID_REQUEST", "Send the provider and purpose.");
        }
        return service.create(member, request);
    }

    @GetMapping("/v1/bank-feeds/connections")
    @Operation(summary = "List the workspace's connections with consent and feed health")
    List<ConnectionView> list(CurrentMember member) {
        return service.list(member);
    }

    @GetMapping("/v1/bank-feeds/connections/{connectionId}")
    @Operation(summary = "Return one connection with consent and feed health")
    ConnectionView get(CurrentMember member, @PathVariable UUID connectionId) {
        return service.get(member, connectionId);
    }

    @PostMapping("/v1/bank-feeds/connections/{connectionId}/consent-callback")
    @Operation(summary = "Complete a redirect consent with the state and code the provider returned")
    ConnectionView callback(CurrentMember member, @PathVariable UUID connectionId,
            @RequestBody BankFeedViews.CallbackRequest request) {
        return service.completeConsent(member, connectionId, request);
    }

    @PostMapping("/v1/bank-feeds/connections/{connectionId}/refresh")
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Queue a refresh; poll the returned job")
    BankFeedViews.RefreshResponse refresh(CurrentMember member, @PathVariable UUID connectionId) {
        return new BankFeedViews.RefreshResponse(service.requestRefresh(member, connectionId));
    }

    @PostMapping("/v1/bank-feeds/connections/{connectionId}/reconnect")
    @Operation(summary = "Renew consent, keeping records and cursors; may return a consent URL")
    ConnectionView reconnect(CurrentMember member, @PathVariable UUID connectionId) {
        return service.reconnect(member, connectionId);
    }

    @DeleteMapping("/v1/bank-feeds/connections/{connectionId}")
    @Operation(summary = "Revoke: withdraw consent, delete provider tokens and stop collection")
    ConnectionView revoke(CurrentMember member, @PathVariable UUID connectionId) {
        return service.revoke(member, connectionId);
    }

    @GetMapping("/v1/bank-feeds/{connectionId}/proposals")
    @Operation(summary = "List provider transactions as import proposals; never posted automatically")
    BankFeedViews.ProposalsResponse proposals(CurrentMember member, @PathVariable UUID connectionId,
            @RequestParam(required = false) String status) {
        return new BankFeedViews.ProposalsResponse(connectionId,
                reconciler.proposals(service.find(member, connectionId), status));
    }

    @PostMapping("/v1/bank-feeds/{connectionId}/proposals/{recordId}/decision")
    @Operation(summary = "Accept (naming the journal the client posted) or dismiss a proposal")
    RecordReconciler.Proposal decide(CurrentMember member, @PathVariable UUID connectionId,
            @PathVariable UUID recordId, @RequestBody BankFeedViews.DecisionRequest request) {
        member.requireWriter();
        if (request == null) {
            throw ApiException.badRequest("INVALID_DECISION", "decision must be accepted or dismissed.");
        }
        return reconciler.decide(service.find(member, connectionId), recordId, request.decision(),
                request.journalId(), member.user().id());
    }

    @PostMapping("/v1/bank-feeds/webhooks/{provider}")
    @Operation(summary = "Provider webhook, verified by HMAC-SHA256 signature, timestamp and delivery id")
    ResponseEntity<BankFeedViews.WebhookResponse> webhook(@PathVariable String provider,
            @RequestHeader(name = "X-Webhook-Id", required = false) String deliveryId,
            @RequestHeader(name = "X-Webhook-Timestamp", required = false) String timestamp,
            @RequestHeader(name = "X-Webhook-Signature", required = false) String signature,
            @RequestBody(required = false) byte[] body) {
        String outcome = webhooks.receive(provider, deliveryId, timestamp, signature, body);
        return ResponseEntity
                .status("duplicate".equals(outcome) ? HttpStatus.OK : HttpStatus.ACCEPTED)
                .body(new BankFeedViews.WebhookResponse(outcome));
    }
}
