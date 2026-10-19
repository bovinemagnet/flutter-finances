package com.paulsnow.finance.server.workspace;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.core.money.CurrencyUnit;
import com.paulsnow.finance.server.common.ApiException;

/**
 * Resolves callers, workspaces, memberships and devices, and exposes the
 * workspace lifecycle steps the deletion job needs. Lookups never reveal
 * whether a workspace or device exists to someone who is not entitled to
 * it.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class WorkspaceDirectory {

    private static final Duration LAST_SEEN_GRANULARITY = Duration.ofMinutes(1);

    private final JdbcClient jdbc;
    private final Clock clock;

    WorkspaceDirectory(JdbcClient jdbc, Clock clock) {
        this.jdbc = jdbc;
        this.clock = clock;
    }

    /**
     * Returns the authenticated caller, creating the user record on first
     * sight of an OIDC subject.
     *
     * @return the caller
     * @throws ApiException 401 when there is no JWT subject
     */
    @Transactional
    public CurrentUser currentUser() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (!(authentication instanceof JwtAuthenticationToken token) || token.getToken().getSubject() == null) {
            throw new ApiException(org.springframework.http.HttpStatus.UNAUTHORIZED, "UNAUTHENTICATED",
                    "Sign in to continue.");
        }
        String subject = token.getToken().getSubject();
        jdbc.sql("insert into app_user (id, subject, created_at) values (?, ?, ?) on conflict (subject) do nothing")
                .params(Ids.newUuid(), subject, Timestamp.from(now()))
                .update();
        UUID id = jdbc.sql("select id from app_user where subject = ?").param(subject).query(UUID.class).single();
        return new CurrentUser(id, subject);
    }

    /**
     * Returns an active workspace.
     *
     * @param workspaceId identifier
     * @return the workspace, or empty when unknown or being deleted
     */
    public Optional<WorkspaceInfo> findActive(UUID workspaceId) {
        return jdbc.sql("select id, name, currency, currency_exponent, timezone from workspace "
                        + "where id = ? and status = 'active'")
                .param(workspaceId)
                .query(WorkspaceDirectory::mapWorkspace)
                .optional();
    }

    /**
     * Returns the caller's membership of an active workspace.
     *
     * @param user        the caller
     * @param workspaceId workspace
     * @return the membership
     * @throws ApiException 404 {@code WORKSPACE_NOT_FOUND} when not a member
     */
    public CurrentMember requireMember(CurrentUser user, UUID workspaceId) {
        return jdbc.sql("select w.id, w.name, w.currency, w.currency_exponent, w.timezone, m.role "
                        + "from workspace w join membership m on m.workspace_id = w.id "
                        + "where w.id = ? and m.user_id = ? and w.status = 'active'")
                .params(workspaceId, user.id())
                .query((rs, row) -> new CurrentMember(user, mapWorkspace(rs, row), rs.getString("role")))
                .optional()
                .orElseThrow(WorkspaceDirectory::workspaceNotFound);
    }

    /**
     * Returns the caller acting through a registered, unrevoked device of
     * their own.
     *
     * @param user                the caller
     * @param deviceId            device from {@code X-Device-Id}
     * @param expectedWorkspaceId workspace from {@code X-Workspace-Id}, or null
     * @return the device context
     * @throws ApiException 403 {@code DEVICE_NOT_AUTHORISED} or {@code DEVICE_REVOKED}
     */
    public CurrentDevice requireDevice(CurrentUser user, UUID deviceId, UUID expectedWorkspaceId) {
        DeviceRow device = findDevice(deviceId)
                .filter(d -> d.userId().equals(user.id()))
                .orElseThrow(() -> ApiException.forbidden("DEVICE_NOT_AUTHORISED",
                        "This device is not registered to you."));
        if (device.revokedAt() != null) {
            throw ApiException.forbidden("DEVICE_REVOKED", "This device's cloud access has been revoked.");
        }
        if (expectedWorkspaceId != null && !expectedWorkspaceId.equals(device.workspaceId())) {
            throw ApiException.forbidden("DEVICE_NOT_AUTHORISED", "This device belongs to another workspace.");
        }
        CurrentMember member = requireMember(user, device.workspaceId());
        Instant now = now();
        jdbc.sql("update device set last_seen_at = ? where id = ? and (last_seen_at is null or last_seen_at < ?)")
                .params(Timestamp.from(now), deviceId, Timestamp.from(now.minus(LAST_SEEN_GRANULARITY)))
                .update();
        return new CurrentDevice(member, deviceId);
    }

    /**
     * Returns the workspace of a caller's own unrevoked device.
     *
     * @param user     the caller
     * @param deviceId device
     * @return the workspace identifier, or empty
     */
    public Optional<UUID> workspaceOfDevice(CurrentUser user, UUID deviceId) {
        return findDevice(deviceId)
                .filter(d -> d.userId().equals(user.id()) && d.revokedAt() == null)
                .map(DeviceRow::workspaceId);
    }

    /**
     * Returns whether {@code workspaceId} belonged to a deleted workspace.
     *
     * @param workspaceId identifier
     * @return true when deletion is suppressing reuse
     */
    public boolean isDeletionSuppressed(UUID workspaceId) {
        return jdbc.sql("select count(*) from workspace_deletion_suppression where workspace_id = ?")
                .param(workspaceId).query(Long.class).single() > 0;
    }

    /**
     * First deletion step (SEC 05): hides the workspace from every API,
     * revokes every device and records the deletion suppression entry, all
     * in one transaction.
     *
     * @param workspaceId workspace
     */
    @Transactional
    public void beginDeletion(UUID workspaceId) {
        Instant now = now();
        jdbc.sql("update workspace set status = 'deleting', updated_at = ? where id = ?")
                .params(Timestamp.from(now), workspaceId).update();
        jdbc.sql("update device set revoked_at = ? where workspace_id = ? and revoked_at is null")
                .params(Timestamp.from(now), workspaceId).update();
        jdbc.sql("insert into workspace_deletion_suppression (workspace_id, deleted_at) values (?, ?) "
                        + "on conflict (workspace_id) do nothing")
                .params(workspaceId, Timestamp.from(now)).update();
    }

    /**
     * Final deletion step: removes the workspace, its memberships and
     * devices. The suppression entry remains.
     *
     * @param workspaceId workspace
     */
    @Transactional
    public void purgeWorkspace(UUID workspaceId) {
        jdbc.sql("delete from workspace where id = ?").param(workspaceId).update();
    }

    /**
     * Returns the role of {@code user} in a workspace in any state, used to
     * authorise deletion requests.
     *
     * @param user        caller
     * @param workspaceId workspace
     * @return the role, or empty when not a member
     */
    public Optional<String> roleOf(CurrentUser user, UUID workspaceId) {
        return jdbc.sql("select role from membership where workspace_id = ? and user_id = ?")
                .params(workspaceId, user.id()).query(String.class).optional();
    }

    // Package-private operations used by this module's controllers.

    record DeviceRow(UUID id, UUID workspaceId, UUID userId, String name, String platform, Instant registeredAt,
            Instant revokedAt, Instant lastSeenAt) {
    }

    Optional<DeviceRow> findDevice(UUID deviceId) {
        return jdbc.sql("select * from device where id = ?").param(deviceId).query(WorkspaceDirectory::mapDevice)
                .optional();
    }

    List<DeviceRow> devicesOf(UUID workspaceId) {
        return jdbc.sql("select * from device where workspace_id = ? order by registered_at")
                .param(workspaceId).query(WorkspaceDirectory::mapDevice).list();
    }

    @Transactional
    WorkspaceInfo createWorkspace(CurrentUser user, UUID id, String name, CurrencyUnit currency, ZoneId timezone) {
        if (isDeletionSuppressed(id)) {
            throw ApiException.conflict("WORKSPACE_DELETED", "This workspace was deleted and cannot be reused.");
        }
        Timestamp now = Timestamp.from(now());
        int inserted = jdbc.sql("insert into workspace (id, name, currency, currency_exponent, timezone, status, "
                        + "created_by, created_at, updated_at) values (?, ?, ?, ?, ?, 'active', ?, ?, ?) "
                        + "on conflict (id) do nothing")
                .params(id, name, currency.code(), currency.exponent(), timezone.getId(), user.id(), now, now)
                .update();
        if (inserted == 0) {
            throw ApiException.conflict("WORKSPACE_EXISTS", "A workspace with this identifier already exists.");
        }
        jdbc.sql("insert into membership (workspace_id, user_id, role, created_at) values (?, ?, 'owner', ?)")
                .params(id, user.id(), now).update();
        return new WorkspaceInfo(id, name, currency, timezone);
    }

    List<CurrentMember> membershipsOf(CurrentUser user) {
        return jdbc.sql("select w.id, w.name, w.currency, w.currency_exponent, w.timezone, m.role "
                        + "from workspace w join membership m on m.workspace_id = w.id "
                        + "where m.user_id = ? and w.status = 'active' order by w.created_at")
                .param(user.id())
                .query((rs, row) -> new CurrentMember(user, mapWorkspace(rs, row), rs.getString("role")))
                .list();
    }

    @Transactional
    boolean registerDevice(CurrentMember member, UUID deviceId, String name, String platform) {
        Optional<DeviceRow> existing = findDevice(deviceId);
        if (existing.isPresent()) {
            DeviceRow device = existing.get();
            if (!device.userId().equals(member.user().id()) || !device.workspaceId().equals(member.workspaceId())) {
                throw ApiException.conflict("DEVICE_EXISTS", "This device identifier is already registered.");
            }
            if (device.revokedAt() != null) {
                throw ApiException.conflict("DEVICE_REVOKED",
                        "This device was revoked; register it under a new identifier.");
            }
            return false;
        }
        jdbc.sql("insert into device (id, workspace_id, user_id, name, platform, registered_at) "
                        + "values (?, ?, ?, ?, ?, ?)")
                .params(deviceId, member.workspaceId(), member.user().id(), name, platform, Timestamp.from(now()))
                .update();
        return true;
    }

    @Transactional
    void revokeDevice(UUID deviceId) {
        jdbc.sql("update device set revoked_at = ? where id = ? and revoked_at is null")
                .params(Timestamp.from(now()), deviceId).update();
    }

    Instant now() {
        return clock.instant();
    }

    static ApiException workspaceNotFound() {
        return ApiException.notFound("WORKSPACE_NOT_FOUND", "Workspace not found.");
    }

    private static WorkspaceInfo mapWorkspace(ResultSet rs, int row) throws SQLException {
        return new WorkspaceInfo(rs.getObject("id", UUID.class), rs.getString("name"),
                new CurrencyUnit(rs.getString("currency").trim(), rs.getInt("currency_exponent")),
                ZoneId.of(rs.getString("timezone")));
    }

    private static DeviceRow mapDevice(ResultSet rs, int row) throws SQLException {
        return new DeviceRow(rs.getObject("id", UUID.class), rs.getObject("workspace_id", UUID.class),
                rs.getObject("user_id", UUID.class), rs.getString("name"), rs.getString("platform"),
                instant(rs, "registered_at"), instant(rs, "revoked_at"), instant(rs, "last_seen_at"));
    }

    private static Instant instant(ResultSet rs, String column) throws SQLException {
        Timestamp value = rs.getTimestamp(column);
        return value == null ? null : value.toInstant();
    }
}
