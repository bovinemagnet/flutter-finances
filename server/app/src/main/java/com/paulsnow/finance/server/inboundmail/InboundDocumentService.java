package com.paulsnow.finance.server.inboundmail;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.storage.PresignedRequest;
import com.paulsnow.finance.server.workspace.CurrentMember;

/**
 * What a member's device collects: their own waiting documents, a short-lived
 * link to each, and notices about what did not become a receipt. Someone else's
 * document looks exactly like a missing one (A17).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
class InboundDocumentService {

    private static final int MAX_CODE = 32;
    private static final int MAX_DETAIL = 200;
    private static final int RECENT_LIMIT = 20;

    record Document(UUID id, String fileName, String contentType, long sizeBytes, String sha256, Instant receivedAt) {
    }

    record Rejection(String fileName, String code, String detail) {
    }

    record Notice(UUID messageId, String sender, Instant receivedAt, String outcome, List<Rejection> rejections) {
    }

    record Recent(UUID messageId, String sender, Instant receivedAt, String outcome) {
    }

    record Inbox(List<Document> documents, List<Notice> notices, List<Recent> recent) {
    }

    private record Owned(UUID id, String objectKey, String state) {
    }

    private final JdbcClient jdbc;
    private final ObjectStorage storage;
    private final ApplicationEventPublisher events;

    InboundDocumentService(JdbcClient jdbc, ObjectStorage storage, ApplicationEventPublisher events) {
        this.jdbc = jdbc;
        this.storage = storage;
        this.events = events;
    }

    Inbox inbox(CurrentMember member) {
        member.requireWriter();
        List<Document> documents = jdbc.sql("select d.id, d.file_name, d.content_type, d.size_bytes, d.sha256, "
                        + "m.received_at from inbound_document d join inbound_message m on m.id = d.message_id "
                        + "where m.workspace_id = ? and m.user_id = ? and d.state = 'waiting' "
                        + "order by m.received_at, d.attachment_index")
                .params(member.workspaceId(), member.user().id())
                .query((rs, row) -> new Document(rs.getObject("id", UUID.class), rs.getString("file_name"),
                        rs.getString("content_type"), rs.getLong("size_bytes"), rs.getString("sha256"),
                        rs.getTimestamp("received_at").toInstant()))
                .list();
        return new Inbox(documents, notices(member), recent(member));
    }

    private List<Recent> recent(CurrentMember member) {
        return jdbc.sql("select id, sender, received_at, outcome from inbound_message "
                        + "where workspace_id = ? and user_id = ? order by received_at desc, id limit ?")
                .params(member.workspaceId(), member.user().id(), RECENT_LIMIT)
                .query((rs, row) -> new Recent(rs.getObject("id", UUID.class), rs.getString("sender"),
                        rs.getTimestamp("received_at").toInstant(), rs.getString("outcome")))
                .list();
    }

    private List<Notice> notices(CurrentMember member) {
        Map<UUID, Notice> notices = new LinkedHashMap<>();
        jdbc.sql("select m.id as message_id, m.sender, m.received_at, m.outcome, d.file_name, d.rejection_code, "
                        + "d.rejection_detail from inbound_message m left join inbound_document d "
                        + "on d.message_id = m.id and d.state = 'rejected' "
                        + "where m.workspace_id = ? and m.user_id = ? and m.outcome <> 'processing' and (m.outcome in "
                        + "('no_attachment', 'rejected', 'rate_limited', 'failed') or d.id is not null) "
                        + "order by m.received_at desc, d.attachment_index")
                .params(member.workspaceId(), member.user().id())
                .query(rs -> {
                    UUID id = rs.getObject("message_id", UUID.class);
                    Notice notice = notices.computeIfAbsent(id, key -> {
                        try {
                            return new Notice(key, rs.getString("sender"), rs.getTimestamp("received_at").toInstant(),
                                    rs.getString("outcome"), new ArrayList<>());
                        } catch (java.sql.SQLException e) {
                            throw new IllegalStateException(e);
                        }
                    });
                    String code = rs.getString("rejection_code");
                    if (code != null) {
                        notice.rejections().add(new Rejection(rs.getString("file_name"), code,
                                rs.getString("rejection_detail")));
                    }
                });
        return List.copyOf(notices.values());
    }

    PresignedRequest download(CurrentMember member, UUID documentId) {
        member.requireWriter();
        Owned document = owned(member, documentId).filter(d -> "waiting".equals(d.state()))
                .orElseThrow(InboundDocumentService::notFound);
        return storage.presignGet(document.objectKey());
    }

    /** Marks a document collected and deletes the server's copy. Repeating it changes nothing. */
    @Transactional
    void acknowledge(CurrentMember member, UUID documentId) {
        Owned document = requireOwned(member, documentId);
        if (!"waiting".equals(document.state())) {
            return;
        }
        jdbc.sql("update inbound_document set state = 'collected', object_key = null where id = ?").param(documentId)
                .update();
        storage.delete(document.objectKey());
        events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(), "inbound_mail.collected",
                "inbound_document", documentId));
    }

    /** Records why a device refused a document, so it is not offered again, and deletes the server's copy. */
    @Transactional
    void reject(CurrentMember member, UUID documentId, String code, String detail) {
        Owned document = requireOwned(member, documentId);
        if (!"waiting".equals(document.state())) {
            return;
        }
        jdbc.sql("update inbound_document set state = 'rejected', object_key = null, rejection_code = ?, "
                        + "rejection_detail = ? where id = ?")
                .params(bounded(code, MAX_CODE), detail == null ? null : bounded(detail, MAX_DETAIL), documentId)
                .update();
        // With nothing left that arrived or could, the whole email was refused.
        jdbc.sql("update inbound_message m set outcome = 'rejected' where m.id = "
                        + "(select message_id from inbound_document where id = ?) and not exists "
                        + "(select 1 from inbound_document d where d.message_id = m.id "
                        + "and d.state in ('waiting', 'collected'))")
                .param(documentId).update();
        storage.delete(document.objectKey());
        events.publishEvent(AuditEvent.of(member.workspaceId(), member.user().id(),
                "inbound_mail.rejected_on_device", "inbound_document", documentId));
    }

    private Owned requireOwned(CurrentMember member, UUID documentId) {
        member.requireWriter();
        return owned(member, documentId).orElseThrow(InboundDocumentService::notFound);
    }

    private Optional<Owned> owned(CurrentMember member, UUID documentId) {
        return jdbc.sql("select d.id, d.object_key, d.state from inbound_document d "
                        + "join inbound_message m on m.id = d.message_id "
                        + "where d.id = ? and m.workspace_id = ? and m.user_id = ?")
                .params(documentId, member.workspaceId(), member.user().id())
                .query((rs, row) -> new Owned(rs.getObject("id", UUID.class), rs.getString("object_key"),
                        rs.getString("state")))
                .optional();
    }

    private static String bounded(String text, int length) {
        String clean = (text == null ? "REJECTED" : text).replaceAll("\\p{C}", "");
        return clean.length() <= length ? clean : clean.substring(0, length);
    }

    private static ApiException notFound() {
        return ApiException.notFound("NOT_FOUND", "Not found.");
    }
}
