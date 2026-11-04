package com.paulsnow.finance.server.inboundmail;

import java.io.InputStream;
import java.time.Instant;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.storage.PresignedRequest;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Forwarding addresses, provider deliveries and collection.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Inbound mail")
class InboundMailController {

    record StatusResponse(boolean available) {
    }

    record AddressResponse(String address, Instant createdAt) {
    }

    record DeliveryResponse(String status) {
    }

    record DownloadResponse(String url, Instant expiresAt) {
    }

    record RejectRequest(String code, String detail) {
    }

    private final InboundAddressService addresses;
    private final InboundDeliveryReceiver deliveries;
    private final InboundDocumentService documents;
    private final WorkspaceDirectory workspaces;

    InboundMailController(InboundAddressService addresses, InboundDeliveryReceiver deliveries,
            InboundDocumentService documents, WorkspaceDirectory workspaces) {
        this.addresses = addresses;
        this.deliveries = deliveries;
        this.documents = documents;
        this.workspaces = workspaces;
    }

    @PostMapping("/v1/inbound-mail/webhooks/{provider}")
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Provider delivery, verified by signature and timestamp, and handled in the background")
    DeliveryResponse deliver(@PathVariable String provider,
            @RequestHeader(name = "X-Webhook-Id", required = false) String deliveryId,
            @RequestHeader(name = "X-Webhook-Timestamp", required = false) String timestamp,
            @RequestHeader(name = "X-Webhook-Signature", required = false) String signature,
            InputStream body) {
        deliveries.receive(provider, deliveryId, timestamp, signature, body);
        return new DeliveryResponse("accepted");
    }

    @GetMapping("/v1/inbound-mail/status")
    @Operation(summary = "Whether email forwarding is available on this server")
    StatusResponse status(CurrentUser user) {
        return new StatusResponse(addresses.available());
    }

    @GetMapping("/v1/workspaces/{workspaceId}/inbound-address")
    @Operation(summary = "Show the caller's forwarding address; 404 when it is turned off")
    AddressResponse address(CurrentUser user, @PathVariable UUID workspaceId) {
        InboundAddressService.Shown shown = addresses.show(workspaces.requireMember(user, workspaceId));
        return new AddressResponse(shown.address(), shown.createdAt());
    }

    @PutMapping("/v1/workspaces/{workspaceId}/inbound-address")
    @Operation(summary = "Turn on the caller's forwarding address, replacing any existing one")
    AddressResponse createOrReplace(CurrentUser user, @PathVariable UUID workspaceId) {
        InboundAddressService.Shown shown = addresses.createOrReplace(workspaces.requireMember(user, workspaceId));
        return new AddressResponse(shown.address(), shown.createdAt());
    }

    @DeleteMapping("/v1/workspaces/{workspaceId}/inbound-address")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Turn off the caller's forwarding address; waiting documents can still be collected")
    void revoke(CurrentUser user, @PathVariable UUID workspaceId) {
        addresses.revoke(workspaces.requireMember(user, workspaceId));
    }

    @GetMapping("/v1/workspaces/{workspaceId}/inbound-documents")
    @Operation(summary = "List the caller's waiting documents and notices about what did not become a receipt")
    InboundDocumentService.Inbox inbox(CurrentUser user, @PathVariable UUID workspaceId) {
        return documents.inbox(workspaces.requireMember(user, workspaceId));
    }

    @GetMapping("/v1/workspaces/{workspaceId}/inbound-documents/{documentId}/download")
    @Operation(summary = "Get a short-lived download URL for one of the caller's waiting documents")
    DownloadResponse download(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID documentId) {
        PresignedRequest signed = documents.download(workspaces.requireMember(user, workspaceId), documentId);
        return new DownloadResponse(signed.url(), signed.expiresAt());
    }

    @PostMapping("/v1/workspaces/{workspaceId}/inbound-documents/{documentId}/acknowledge")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Mark a document collected after it is saved on the device, and delete the server's copy")
    void acknowledge(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID documentId) {
        documents.acknowledge(workspaces.requireMember(user, workspaceId), documentId);
    }

    @PostMapping("/v1/workspaces/{workspaceId}/inbound-documents/{documentId}/reject")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Record why the device refused a document, and delete the server's copy")
    void reject(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID documentId,
            @RequestBody RejectRequest request) {
        documents.reject(workspaces.requireMember(user, workspaceId), documentId, request.code(), request.detail());
    }
}
