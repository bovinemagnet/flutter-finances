package com.paulsnow.finance.server.audit;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Lets owners review their workspace's audit events.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Audit")
class AuditController {

    /** A page of events, newest first. */
    record AuditPage(List<AuditLog.StoredEvent> events) {
    }

    private final AuditLog audit;
    private final WorkspaceDirectory workspaces;

    AuditController(AuditLog audit, WorkspaceDirectory workspaces) {
        this.audit = audit;
        this.workspaces = workspaces;
    }

    @GetMapping("/v1/workspaces/{workspaceId}/audit-events")
    @Operation(summary = "Audit events of the workspace, newest first (owners only)")
    AuditPage list(CurrentUser user, @PathVariable UUID workspaceId,
            @RequestParam(required = false) Integer limit, @RequestParam(required = false) Instant before) {
        CurrentMember member = workspaces.requireMember(user, workspaceId);
        member.requireOwner();
        int size = limit == null ? 100 : Math.max(1, Math.min(limit, 500));
        return new AuditPage(audit.events(workspaceId, size, before));
    }
}
