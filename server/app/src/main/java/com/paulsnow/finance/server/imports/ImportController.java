package com.paulsnow.finance.server.imports;

import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.imports.ImportViews.BatchView;
import com.paulsnow.finance.server.workspace.CurrentMember;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * CSV import endpoints (IMP 01-03), scoped to the caller's workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/imports")
@Tag(name = "Imports")
class ImportController {

    private final ImportService imports;

    ImportController(ImportService imports) {
        this.imports = imports;
    }

    @PostMapping("/preview")
    @Operation(summary = "Parse a CSV statement and preview rows, totals, errors and candidates; the same file "
            + "and settings return the same batch")
    BatchView preview(CurrentMember member, @RequestBody ImportViews.PreviewRequest request) {
        member.requireWriter();
        if (request == null) {
            throw ApiException.badRequest("INVALID_REQUEST", "Send the statement and mapping.");
        }
        return imports.preview(member, request);
    }

    @PostMapping("/{batchId}/commit")
    @Operation(summary = "Commit a previewed batch; repeating it creates nothing new (A12). Large batches answer "
            + "202 with a job to poll")
    ResponseEntity<BatchView> commit(CurrentMember member, @PathVariable UUID batchId,
            @RequestBody(required = false) ImportViews.CommitRequest request) {
        member.requireWriter();
        imports.requireVisible(member, batchId);
        ImportService.CommitOutcome outcome = imports.commit(member, batchId,
                request == null ? null : request.decisions());
        return ResponseEntity.status(outcome.accepted() ? HttpStatus.ACCEPTED : HttpStatus.OK).body(outcome.batch());
    }

    @PostMapping("/{batchId}/rollback")
    @Operation(summary = "Reverse the entries a batch created; entries edited since are held for review")
    BatchView rollback(CurrentMember member, @PathVariable UUID batchId) {
        member.requireWriter();
        imports.requireVisible(member, batchId);
        return imports.rollback(member, batchId);
    }

    @GetMapping("/{batchId}")
    @Operation(summary = "Return a batch with a page of its rows and their provenance")
    BatchView get(CurrentMember member, @PathVariable UUID batchId,
            @RequestParam(required = false) Integer offset, @RequestParam(required = false) Integer limit) {
        imports.requireVisible(member, batchId);
        return imports.get(member, batchId, offset, limit);
    }
}
