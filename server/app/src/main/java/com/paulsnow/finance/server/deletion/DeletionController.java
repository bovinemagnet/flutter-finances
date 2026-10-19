package com.paulsnow.finance.server.deletion;

import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.workspace.CurrentUser;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * Workspace deletion endpoints.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@Tag(name = "Workspaces")
class DeletionController {

    private final DeletionService deletions;

    DeletionController(DeletionService deletions) {
        this.deletions = deletions;
    }

    @DeleteMapping("/v1/workspaces/{workspaceId}")
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Delete a workspace: revokes devices at once and queues a tracked deletion job")
    DeletionService.DeletionView delete(CurrentUser user, @PathVariable UUID workspaceId) {
        return deletions.request(user, workspaceId);
    }

    @GetMapping("/v1/workspaces/{workspaceId}/deletion")
    @Operation(summary = "Progress of a deletion, for the user who requested it")
    DeletionService.DeletionView status(CurrentUser user, @PathVariable UUID workspaceId) {
        return deletions.status(user, workspaceId);
    }
}
