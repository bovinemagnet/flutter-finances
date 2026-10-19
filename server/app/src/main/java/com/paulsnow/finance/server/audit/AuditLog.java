package com.paulsnow.finance.server.audit;

import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.common.CorrelationIds;

/**
 * Stores audit events and applies their retention. The listener runs
 * synchronously, so an event is committed or rolled back with the action
 * that published it.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class AuditLog {

    private static final Logger LOG = LoggerFactory.getLogger(AuditLog.class);

    private static final Instant END_OF_TIME = Instant.parse("9999-12-31T00:00:00Z");

    /**
     * A stored event as owners see it.
     *
     * @param id          event identifier
     * @param kind        what happened
     * @param actorUserId acting user, or null for the system
     * @param subjectType subject kind
     * @param subjectId   subject identifier
     * @param detail      short code such as a role
     * @param occurredAt  when it happened
     */
    public record StoredEvent(UUID id, String kind, UUID actorUserId, String subjectType, String subjectId,
            String detail, Instant occurredAt) {
    }

    private final JdbcClient jdbc;
    private final Clock clock;
    private final AuditProperties properties;

    AuditLog(JdbcClient jdbc, Clock clock, AuditProperties properties) {
        this.jdbc = jdbc;
        this.clock = clock;
        this.properties = properties;
    }

    @EventListener
    void record(AuditEvent event) {
        jdbc.sql("insert into audit_event (id, workspace_id, actor_user_id, kind, subject_type, subject_id, detail, "
                        + "correlation_id, occurred_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                .params(Ids.newUuid(), event.workspaceId(), event.actorUserId(), event.kind(), event.subjectType(),
                        event.subjectId(), event.detail(), CorrelationIds.current(),
                        Timestamp.from(clock.instant()))
                .update();
    }

    /**
     * Lists a workspace's events, newest first.
     *
     * @param workspaceId workspace
     * @param limit       page size
     * @param before      only events before this instant, or null
     * @return events
     */
    public List<StoredEvent> events(UUID workspaceId, int limit, Instant before) {
        return jdbc.sql("select * from audit_event where workspace_id = ? and occurred_at < ? "
                        + "order by occurred_at desc, id limit ?")
                .params(workspaceId, Timestamp.from(before == null ? END_OF_TIME : before), limit)
                .query((rs, row) -> new StoredEvent(rs.getObject("id", UUID.class), rs.getString("kind"),
                        rs.getObject("actor_user_id", UUID.class), rs.getString("subject_type"),
                        rs.getString("subject_id"), rs.getString("detail"),
                        rs.getTimestamp("occurred_at").toInstant()))
                .list();
    }

    /**
     * Deletes events older than the retention period.
     *
     * @return events deleted
     */
    @Transactional
    public int purgeExpired() {
        int purged = jdbc.sql("delete from audit_event where occurred_at < ?")
                .param(Timestamp.from(clock.instant().minus(properties.retention()))).update();
        LOG.info("Audit retention purge removed {} events", purged);
        return purged;
    }
}
