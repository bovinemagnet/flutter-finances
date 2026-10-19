package com.paulsnow.finance.server.receipts;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.storage.PresignedRequest;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

/**
 * Receipt document endpoints of {@code spec/sync/protocol.md} (SYNC 05).
 * Receipt bytes never pass through this service's API; clients upload and
 * download directly with short-lived signed URLs.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/receipts")
@Tag(name = "Receipts")
class ReceiptController {

    /** Requests an upload URL for one asset of a receipt the workspace owns. */
    record UploadIntentRequest(@NotNull UUID receiptId, @NotNull UUID assetId, String kind, String contentType,
            long sizeBytes, String sha256) {
    }

    /** A short-lived presigned PUT. */
    record UploadIntentResponse(String uploadUrl, Map<String, String> headers, Instant expiresAt) {
    }

    /** Names the uploaded asset to verify. */
    record CompleteRequest(@NotNull UUID assetId) {
    }

    /** The asset's status after completion. */
    record CompleteResponse(String status) {
    }

    /** A short-lived presigned GET. */
    record DownloadResponse(String downloadUrl, Instant expiresAt) {
    }

    private final ReceiptService receipts;

    ReceiptController(ReceiptService receipts) {
        this.receipts = receipts;
    }

    @PostMapping("/upload-intents")
    @Operation(summary = "Get a short-lived upload URL; repeating it targets the same object")
    UploadIntentResponse intent(CurrentMember member, @Valid @RequestBody UploadIntentRequest request) {
        PresignedRequest signed = receipts.createUploadIntent(member.workspaceId(), request.receiptId(),
                request.assetId(), request.kind(), request.contentType(), request.sizeBytes(), request.sha256());
        return new UploadIntentResponse(signed.url(), signed.headers(), signed.expiresAt());
    }

    @PostMapping("/{receiptId}/complete")
    @Operation(summary = "Verify an upload and quarantine it for scanning; repeating it is a no-op")
    CompleteResponse complete(CurrentMember member, @PathVariable UUID receiptId,
            @Valid @RequestBody CompleteRequest request) {
        return new CompleteResponse(receipts.complete(member.workspaceId(), receiptId, request.assetId()));
    }

    @GetMapping("/{receiptId}/assets/{assetId}/download")
    @Operation(summary = "Get a short-lived download URL; 409 ASSET_NOT_AVAILABLE until scanned")
    DownloadResponse download(CurrentMember member, @PathVariable UUID receiptId, @PathVariable UUID assetId) {
        PresignedRequest signed = receipts.download(member.workspaceId(), receiptId, assetId);
        return new DownloadResponse(signed.url(), signed.expiresAt());
    }
}
