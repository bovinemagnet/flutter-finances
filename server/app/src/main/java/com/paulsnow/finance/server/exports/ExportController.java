package com.paulsnow.finance.server.exports;

import java.time.Instant;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.storage.PresignedRequest;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Export endpoints. Exports are never gated by entitlements: any member can
 * export the workspace's data (EXP 01).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/exports")
@Tag(name = "Exports")
class ExportController {

    /** Export options; {@code json} is the only format. */
    record ExportRequest(String format) {
    }

    /** The started export and the job to poll. */
    record ExportStarted(UUID exportId, UUID jobId, String status) {
    }

    /** A short-lived presigned GET of the archive. */
    record DownloadResponse(String downloadUrl, Instant expiresAt) {
    }

    private final ExportService exports;

    ExportController(ExportService exports) {
        this.exports = exports;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Start a complete JSON export; poll GET /v1/jobs/{jobId}")
    ExportStarted start(CurrentMember member, @RequestBody(required = false) ExportRequest request) {
        if (request != null && request.format() != null && !"json".equals(request.format())) {
            throw ApiException.badRequest("UNSUPPORTED_FORMAT", "Only the json format is available.");
        }
        ExportService.ExportView export = exports.start(member.workspaceId());
        return new ExportStarted(export.exportId(), export.jobId(), export.status());
    }

    @GetMapping("/{exportId}")
    @Operation(summary = "Export status")
    ExportService.ExportView get(CurrentMember member, @PathVariable UUID exportId) {
        return exports.find(member.workspaceId(), exportId);
    }

    @GetMapping("/{exportId}/download")
    @Operation(summary = "Short-lived download URL; 409 EXPORT_NOT_READY until the job finishes")
    DownloadResponse download(CurrentMember member, @PathVariable UUID exportId) {
        PresignedRequest signed = exports.download(member.workspaceId(), exportId);
        return new DownloadResponse(signed.url(), signed.expiresAt());
    }
}
