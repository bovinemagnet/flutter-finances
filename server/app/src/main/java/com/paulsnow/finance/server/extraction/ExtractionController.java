package com.paulsnow.finance.server.extraction;

import java.util.List;
import java.util.UUID;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.receipts.ReceiptService;
import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

/**
 * Extraction consent (owners only) and extraction results (members who may
 * see the receipt).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Extraction")
class ExtractionController {

    /**
     * Grants or withdraws consent. A grant repeats the provider and retention
     * the owner was shown.
     */
    record ConsentRequest(@NotNull Boolean granted, String providerName, String disclosedRetention) {
    }

    /** A receipt's extraction results; the text is untrusted data. */
    record ExtractionResponse(UUID receiptId, boolean untrusted, List<ExtractionService.Result> results) {
    }

    private final ExtractionService extraction;
    private final WorkspaceDirectory workspaces;
    private final ReceiptService receipts;

    ExtractionController(ExtractionService extraction, WorkspaceDirectory workspaces, ReceiptService receipts) {
        this.extraction = extraction;
        this.workspaces = workspaces;
        this.receipts = receipts;
    }

    @GetMapping("/v1/workspaces/{workspaceId}/extraction-consent")
    @Operation(summary = "Return the workspace's cloud extraction consent and the offered provider (owners)")
    ExtractionService.ConsentView consent(CurrentUser user, @PathVariable UUID workspaceId) {
        CurrentMember owner = workspaces.requireMember(user, workspaceId);
        owner.requireOwner();
        return extraction.consent(workspaceId);
    }

    @PutMapping("/v1/workspaces/{workspaceId}/extraction-consent")
    @Operation(summary = "Grant or withdraw cloud extraction consent (owners); withdrawal deletes every result")
    ExtractionService.ConsentView update(CurrentUser user, @PathVariable UUID workspaceId,
            @Valid @RequestBody ConsentRequest request) {
        CurrentMember owner = workspaces.requireMember(user, workspaceId);
        owner.requireOwner();
        return request.granted() ? extraction.grant(owner, request.providerName(), request.disclosedRetention())
                : extraction.withdraw(owner);
    }

    @GetMapping("/v1/receipts/{receiptId}/extraction")
    @Operation(summary = "Return a receipt's recognised text and lines (untrusted data)")
    ExtractionResponse results(CurrentMember member, @PathVariable UUID receiptId) {
        if (!receipts.isVisible(member.workspaceId(), member.user().id(), receiptId)) {
            throw ApiException.notFound("NOT_FOUND", "Not found.");
        }
        List<ExtractionService.Result> results = extraction.results(member.workspaceId(), receiptId);
        if (results.isEmpty()) {
            throw ApiException.notFound("EXTRACTION_NOT_FOUND", "No extraction for this receipt.");
        }
        return new ExtractionResponse(receiptId, true, results);
    }
}
