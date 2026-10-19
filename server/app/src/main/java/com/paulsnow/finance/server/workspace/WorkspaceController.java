package com.paulsnow.finance.server.workspace;

import java.time.DateTimeException;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.server.common.ApiException;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Workspace creation and bootstrap. Enabling sync creates a new workspace
 * explicitly; two existing workspaces are never merged, and a cloud restore
 * creates a new workspace rather than replaying into a live one (DATA 03).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/workspaces")
@Tag(name = "Workspaces")
class WorkspaceController {

    /** Request to create a workspace; {@code id} may be generated offline. */
    record CreateWorkspaceRequest(String id, @NotBlank @Size(max = 200) String name, @NotBlank String currency,
            @NotBlank String timezone) {
    }

    /** A workspace as seen by one member. */
    record WorkspaceResponse(UUID id, String name, String currency, int currencyExponent, String timezone,
            String role) {
    }

    /** Everything a client needs to start syncing a workspace. */
    record BootstrapResponse(UUID id, String name, String currency, int currencyExponent, String timezone,
            String role, int schemaVersion, long tombstoneHorizonDays, int maxCommandsPerBatch,
            Instant serverTime) {
    }

    private final WorkspaceDirectory directory;
    private final Duration tombstoneHorizon;
    private final int maxCommandsPerBatch;

    WorkspaceController(WorkspaceDirectory directory,
            @Value("${finance.sync.tombstone-horizon:90d}") Duration tombstoneHorizon,
            @Value("${finance.sync.max-commands-per-batch:500}") int maxCommandsPerBatch) {
        this.directory = directory;
        this.tombstoneHorizon = tombstoneHorizon;
        this.maxCommandsPerBatch = maxCommandsPerBatch;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "Create a workspace owned by the caller")
    WorkspaceResponse create(CurrentUser user, @Valid @RequestBody CreateWorkspaceRequest request) {
        UUID id = request.id() == null ? Ids.newUuid() : parseId(request.id());
        CurrencyUnit currency;
        try {
            currency = CurrencyUnit.of(request.currency().strip().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            throw ApiException.badRequest("INVALID_CURRENCY", "Unknown ISO 4217 currency.");
        }
        ZoneId timezone;
        try {
            timezone = ZoneId.of(request.timezone().strip());
        } catch (DateTimeException e) {
            throw ApiException.badRequest("INVALID_TIMEZONE", "Unknown timezone; use an IANA name.");
        }
        WorkspaceInfo workspace = directory.createWorkspace(user, id, request.name().strip(), currency, timezone);
        return response(new CurrentMember(user, workspace, "owner"));
    }

    @GetMapping
    @Operation(summary = "List the caller's workspaces")
    List<WorkspaceResponse> list(CurrentUser user) {
        return directory.membershipsOf(user).stream().map(WorkspaceController::response).toList();
    }

    @GetMapping("/{workspaceId}")
    @Operation(summary = "Bootstrap a workspace for sync")
    BootstrapResponse bootstrap(CurrentUser user, @PathVariable UUID workspaceId) {
        CurrentMember member = directory.requireMember(user, workspaceId);
        WorkspaceInfo workspace = member.workspace();
        return new BootstrapResponse(workspace.id(), workspace.name(), workspace.currency().code(),
                workspace.currency().exponent(), workspace.timezone().getId(), member.role(), 1,
                tombstoneHorizon.toDays(), maxCommandsPerBatch, directory.now());
    }

    private static WorkspaceResponse response(CurrentMember member) {
        WorkspaceInfo workspace = member.workspace();
        return new WorkspaceResponse(workspace.id(), workspace.name(), workspace.currency().code(),
                workspace.currency().exponent(), workspace.timezone().getId(), member.role());
    }

    private static UUID parseId(String id) {
        try {
            return UUID.fromString(id);
        } catch (IllegalArgumentException e) {
            throw ApiException.badRequest("INVALID_REQUEST", "id must be a UUID.");
        }
    }
}
