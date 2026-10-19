package com.paulsnow.finance.server.households;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;

/**
 * Invitation and membership endpoints of a shared household.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@RestController
@RequestMapping("/v1/workspaces/{workspaceId}")
@Tag(name = "Households")
class HouseholdController {

    /** Invites someone as {@code member} or {@code viewer}; expiry defaults to 72 hours. */
    record CreateInvitationRequest(@NotBlank String role, Integer expiresInHours) {
    }

    /** Proves possession of the invitation token. */
    record AcceptRequest(@NotBlank String token) {
    }

    /** Changes a member's role. */
    record RoleRequest(@NotBlank String role) {
    }

    /** A member as the caller sees them. */
    record MemberView(UUID userId, String role, Instant joinedAt, boolean you) {
    }

    private final InvitationService invitations;
    private final WorkspaceDirectory workspaces;

    HouseholdController(InvitationService invitations, WorkspaceDirectory workspaces) {
        this.invitations = invitations;
        this.workspaces = workspaces;
    }

    @PostMapping("/invitations")
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "Invite someone (owners only); the token is returned once")
    InvitationService.InvitationView invite(CurrentUser user, @PathVariable UUID workspaceId,
            @Valid @RequestBody CreateInvitationRequest request) {
        Duration expiry = request.expiresInHours() == null ? null : Duration.ofHours(request.expiresInHours());
        return invitations.create(workspaces.requireMember(user, workspaceId), request.role(), expiry);
    }

    @GetMapping("/invitations")
    @Operation(summary = "List invitations (owners only); tokens are never shown again")
    List<InvitationService.InvitationView> invitations(CurrentUser user, @PathVariable UUID workspaceId) {
        return invitations.list(workspaces.requireMember(user, workspaceId));
    }

    @DeleteMapping("/invitations/{invitationId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Revoke an unused invitation (owners only)")
    void revoke(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID invitationId) {
        invitations.revoke(workspaces.requireMember(user, workspaceId), invitationId);
    }

    @PostMapping("/invitations/{invitationId}/accept")
    @Operation(summary = "Join the workspace with an invitation token")
    InvitationService.Accepted accept(CurrentUser user, @PathVariable UUID workspaceId,
            @PathVariable UUID invitationId, @Valid @RequestBody AcceptRequest request) {
        return invitations.accept(user, workspaceId, invitationId, request.token());
    }

    @GetMapping("/members")
    @Operation(summary = "List the workspace's members")
    List<MemberView> members(CurrentUser user, @PathVariable UUID workspaceId) {
        workspaces.requireMember(user, workspaceId);
        return workspaces.members(workspaceId).stream()
                .map(m -> new MemberView(m.userId(), m.role(), m.joinedAt(), m.userId().equals(user.id())))
                .toList();
    }

    @PatchMapping("/members/{userId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Change a member's role (owners only); the last owner stays an owner")
    void changeRole(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID userId,
            @Valid @RequestBody RoleRequest request) {
        CurrentMember member = workspaces.requireMember(user, workspaceId);
        member.requireOwner();
        if (!List.of("owner", "member", "viewer").contains(request.role())) {
            throw ApiException.badRequest("INVALID_ROLE", "Roles are owner, member and viewer.");
        }
        workspaces.changeRole(workspaceId, user, userId, request.role());
    }

    @DeleteMapping("/members/{userId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @Operation(summary = "Remove a member (owners) or leave (yourself); revokes their devices at once")
    void remove(CurrentUser user, @PathVariable UUID workspaceId, @PathVariable UUID userId) {
        CurrentMember member = workspaces.requireMember(user, workspaceId);
        if (!userId.equals(user.id())) {
            member.requireOwner();
        }
        workspaces.removeMember(workspaceId, user, userId);
    }
}
