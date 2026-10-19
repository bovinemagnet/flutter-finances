package com.paulsnow.finance.server.households;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.workspace.CurrentMember;
import com.paulsnow.finance.server.workspace.CurrentUser;
import com.paulsnow.finance.server.workspace.WorkspaceDirectory;

/**
 * Creates, lists, revokes and accepts workspace invitations. A token is
 * 256 random bits shown once; only its SHA-256 is stored, and acceptance
 * compares digests in constant time.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class InvitationService {

    static final Duration DEFAULT_EXPIRY = Duration.ofHours(72);
    static final Duration MAX_EXPIRY = Duration.ofDays(30);

    /** An invitation; {@code token} is present only in the creation response. */
    record InvitationView(UUID id, UUID workspaceId, String role, String status, Instant createdAt,
            Instant expiresAt, Instant acceptedAt, String token) {
    }

    /** The membership an accepted invitation granted. */
    record Accepted(UUID workspaceId, String role) {
    }

    private static final SecureRandom RANDOM = new SecureRandom();

    private final JdbcClient jdbc;
    private final WorkspaceDirectory workspaces;
    private final ApplicationEventPublisher events;
    private final Clock clock;

    InvitationService(JdbcClient jdbc, WorkspaceDirectory workspaces, ApplicationEventPublisher events, Clock clock) {
        this.jdbc = jdbc;
        this.workspaces = workspaces;
        this.events = events;
        this.clock = clock;
    }

    @Transactional
    InvitationView create(CurrentMember owner, String role, Duration expiresIn) {
        owner.requireOwner();
        if (!"member".equals(role) && !"viewer".equals(role)) {
            throw ApiException.badRequest("INVALID_ROLE", "Invite as member or viewer.");
        }
        Duration expiry = expiresIn == null ? DEFAULT_EXPIRY : expiresIn;
        if (expiry.isNegative() || expiry.isZero() || expiry.compareTo(MAX_EXPIRY) > 0) {
            throw ApiException.badRequest("INVALID_EXPIRY", "Invitations expire within 30 days.");
        }
        byte[] secret = new byte[32];
        RANDOM.nextBytes(secret);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(secret);
        UUID id = Ids.newUuid();
        Instant now = clock.instant();
        jdbc.sql("insert into workspace_invitation (id, workspace_id, role, token_sha256, status, created_by, "
                        + "created_at, expires_at) values (?, ?, ?, ?, 'pending', ?, ?, ?)")
                .params(id, owner.workspaceId(), role, sha256(token), owner.user().id(), Timestamp.from(now),
                        Timestamp.from(now.plus(expiry)))
                .update();
        events.publishEvent(AuditEvent.of(owner.workspaceId(), owner.user().id(), "invitation.created",
                "invitation", id).withDetail(role));
        InvitationView created = find(owner.workspaceId(), id);
        return new InvitationView(created.id(), created.workspaceId(), created.role(), created.status(),
                created.createdAt(), created.expiresAt(), created.acceptedAt(), token);
    }

    List<InvitationView> list(CurrentMember owner) {
        owner.requireOwner();
        return jdbc.sql("select * from workspace_invitation where workspace_id = ? order by created_at desc")
                .param(owner.workspaceId()).query(this::map).list();
    }

    @Transactional
    void revoke(CurrentMember owner, UUID invitationId) {
        owner.requireOwner();
        InvitationView invitation = find(owner.workspaceId(), invitationId);
        if (!"pending".equals(invitation.status()) && !"expired".equals(invitation.status())) {
            throw ApiException.conflict("INVITATION_NOT_PENDING", "Only an unused invitation can be revoked.");
        }
        jdbc.sql("update workspace_invitation set status = 'revoked', revoked_at = ? where id = ?")
                .params(Timestamp.from(clock.instant()), invitationId).update();
        events.publishEvent(AuditEvent.of(owner.workspaceId(), owner.user().id(), "invitation.revoked",
                "invitation", invitationId));
    }

    /**
     * Accepts an invitation as the calling user. Every failure before the
     * token is proven says only that the invitation was not found.
     */
    @Transactional
    Accepted accept(CurrentUser user, UUID workspaceId, UUID invitationId, String token) {
        record Row(String role, String status, String tokenSha256, Instant expiresAt, UUID acceptedBy) {
        }
        Row row = jdbc.sql("select role, status, token_sha256, expires_at, accepted_by from workspace_invitation "
                        + "where id = ? and workspace_id = ? for update")
                .params(invitationId, workspaceId)
                .query((rs, n) -> new Row(rs.getString("role"), rs.getString("status"),
                        rs.getString("token_sha256").trim(), rs.getTimestamp("expires_at").toInstant(),
                        rs.getObject("accepted_by", UUID.class)))
                .optional()
                .filter(r -> token != null && MessageDigest.isEqual(
                        r.tokenSha256().getBytes(StandardCharsets.US_ASCII),
                        sha256(token).getBytes(StandardCharsets.US_ASCII)))
                .filter(r -> workspaces.findActive(workspaceId).isPresent())
                .orElseThrow(InvitationService::notFound);
        if ("accepted".equals(row.status())) {
            if (user.id().equals(row.acceptedBy())) {
                return new Accepted(workspaceId, row.role());
            }
            throw ApiException.conflict("INVITATION_USED", "This invitation has already been used.");
        }
        if ("revoked".equals(row.status())) {
            throw new ApiException(HttpStatus.GONE, "INVITATION_REVOKED", "This invitation was revoked.");
        }
        if (!row.expiresAt().isAfter(clock.instant())) {
            throw new ApiException(HttpStatus.GONE, "INVITATION_EXPIRED", "This invitation has expired.");
        }
        if (workspaces.roleOf(user, workspaceId).isPresent()) {
            throw ApiException.conflict("ALREADY_MEMBER", "You are already a member of this workspace.");
        }
        workspaces.addMember(workspaceId, user, row.role());
        jdbc.sql("update workspace_invitation set status = 'accepted', accepted_by = ?, accepted_at = ? where id = ?")
                .params(user.id(), Timestamp.from(clock.instant()), invitationId).update();
        events.publishEvent(AuditEvent.of(workspaceId, user.id(), "invitation.accepted", "invitation",
                invitationId));
        return new Accepted(workspaceId, row.role());
    }

    /** Removes a deleted workspace's invitations. */
    int purgeWorkspace(UUID workspaceId) {
        return jdbc.sql("delete from workspace_invitation where workspace_id = ?").param(workspaceId).update();
    }

    private InvitationView find(UUID workspaceId, UUID invitationId) {
        return jdbc.sql("select * from workspace_invitation where id = ? and workspace_id = ?")
                .params(invitationId, workspaceId).query(this::map).optional()
                .orElseThrow(InvitationService::notFound);
    }

    private InvitationView map(ResultSet rs, int row) throws SQLException {
        String status = rs.getString("status");
        Instant expiresAt = rs.getTimestamp("expires_at").toInstant();
        if ("pending".equals(status) && !expiresAt.isAfter(clock.instant())) {
            status = "expired";
        }
        Timestamp accepted = rs.getTimestamp("accepted_at");
        return new InvitationView(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                rs.getString("role"), status, rs.getTimestamp("created_at").toInstant(), expiresAt,
                accepted == null ? null : accepted.toInstant(), null);
    }

    private static ApiException notFound() {
        return ApiException.notFound("INVITATION_NOT_FOUND", "Invitation not found.");
    }

    private static String sha256(String token) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(token.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
