package com.paulsnow.finance.server.common;

import java.util.Objects;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * A security or privacy relevant action, published as an application event
 * and stored by the audit module (SEC 06). The content is minimised by
 * construction: identifiers and short codes only, never amounts, merchants,
 * names, document contents or tokens. Publish it inside the transaction of
 * the action so the record commits with it.
 *
 * @param workspaceId workspace concerned, or null
 * @param actorUserId user who acted, or null for the system
 * @param kind        what happened, for example {@code device.registered}
 * @param subjectType kind of the subject, for example {@code device}
 * @param subjectId   identifier of the subject, or null
 * @param detail      optional short code such as a role ({@code viewer}), or null
 * @author Paul Snow
 * @since 0.0.0
 */
public record AuditEvent(UUID workspaceId, UUID actorUserId, String kind, String subjectType, String subjectId,
        String detail) {

    private static final Pattern KIND = Pattern.compile("[a-z][a-z_]*(\\.[a-z][a-z_]*)+");
    private static final Pattern CODE = Pattern.compile("[a-z][a-z0-9_]{0,31}");
    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z0-9-]{1,64}");

    public AuditEvent {
        Objects.requireNonNull(kind, "kind");
        if (!KIND.matcher(kind).matches()) {
            throw new IllegalArgumentException("Audit kinds are dotted lower-case codes");
        }
        if (subjectType != null && !CODE.matcher(subjectType).matches()) {
            throw new IllegalArgumentException("Audit subject types are short codes");
        }
        if (subjectId != null && !IDENTIFIER.matcher(subjectId).matches()) {
            throw new IllegalArgumentException("Audit subjects are identifiers");
        }
        if (detail != null && !CODE.matcher(detail).matches()) {
            throw new IllegalArgumentException("Audit details are short codes");
        }
    }

    /**
     * Creates an event about one subject.
     *
     * @param workspaceId workspace, or null
     * @param actorUserId acting user, or null
     * @param kind        dotted kind
     * @param subjectType subject kind
     * @param subjectId   subject identifier
     * @return the event
     */
    public static AuditEvent of(UUID workspaceId, UUID actorUserId, String kind, String subjectType,
            UUID subjectId) {
        return new AuditEvent(workspaceId, actorUserId, kind, subjectType,
                subjectId == null ? null : subjectId.toString(), null);
    }

    /**
     * Returns a copy carrying a short detail code.
     *
     * @param code detail such as a role
     * @return the copy
     */
    public AuditEvent withDetail(String code) {
        return new AuditEvent(workspaceId, actorUserId, kind, subjectType, subjectId, code);
    }
}
