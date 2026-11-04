package com.paulsnow.finance.server.inboundmail;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.storage.ObjectStorage;

/**
 * Forwarded messages and their documents.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundMessageStore {

    /** A message's identity and how far handling it has gone. */
    record Handled(UUID id, String outcome) {
    }

    /** What is known about a document before it is stored or refused. */
    record NewDocument(UUID id, UUID messageId, int attachmentIndex, String fileName) {
    }

    private final JdbcClient jdbc;

    InboundMessageStore(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Records a message unless the provider already delivered it, and returns it either way. */
    Handled insertOrFind(InboundAddressStore.Address address, String provider, InboundMessage message, String sender,
            String subject, Instant now, Instant expiresAt) {
        jdbc.sql("insert into inbound_message (id, workspace_id, user_id, provider, provider_message_id, sender, "
                        + "subject, received_at, outcome, expires_at) values (?, ?, ?, ?, ?, ?, ?, ?, 'processing', ?) "
                        + "on conflict (provider, provider_message_id) do nothing")
                .params(UUID.randomUUID(), address.workspaceId(), address.userId(), provider, message.messageId(),
                        sender, subject, Timestamp.from(now), Timestamp.from(expiresAt))
                .update();
        return jdbc.sql("select id, outcome from inbound_message where provider = ? and provider_message_id = ?")
                .params(provider, message.messageId())
                .query((rs, row) -> new Handled(rs.getObject("id", UUID.class), rs.getString("outcome")))
                .single();
    }

    /** Counts the member's other messages since a moment, for the daily limit. */
    long countSince(InboundAddressStore.Address address, Instant since, UUID excluding) {
        return jdbc.sql("select count(*) from inbound_message where workspace_id = ? and user_id = ? "
                        + "and received_at > ? and id <> ?")
                .params(address.workspaceId(), address.userId(), Timestamp.from(since), excluding)
                .query(Long.class).single();
    }

    void setOutcome(UUID messageId, String outcome) {
        jdbc.sql("update inbound_message set outcome = ? where id = ?").params(outcome, messageId).update();
    }

    boolean documentExists(UUID messageId, int attachmentIndex) {
        return jdbc.sql("select count(*) from inbound_document where message_id = ? and attachment_index = ?")
                .params(messageId, attachmentIndex).query(Long.class).single() > 0;
    }

    void insertWaiting(NewDocument document, String objectKey, String contentType, long size, String sha256) {
        jdbc.sql("insert into inbound_document (id, message_id, attachment_index, file_name, object_key, content_type, "
                        + "size_bytes, sha256, state) values (?, ?, ?, ?, ?, ?, ?, ?, 'waiting') "
                        + "on conflict (message_id, attachment_index) do nothing")
                .params(document.id(), document.messageId(), document.attachmentIndex(), document.fileName(), objectKey,
                        contentType, size, sha256)
                .update();
    }

    void insertRejected(NewDocument document, String code) {
        jdbc.sql("insert into inbound_document (id, message_id, attachment_index, file_name, state, rejection_code) "
                        + "values (?, ?, ?, ?, 'rejected', ?) on conflict (message_id, attachment_index) do nothing")
                .params(document.id(), document.messageId(), document.attachmentIndex(), document.fileName(), code)
                .update();
    }

    List<String> documentStates(UUID messageId) {
        return jdbc.sql("select state from inbound_document where message_id = ?").param(messageId)
                .query(String.class).list();
    }

    /** Removes messages past their expiry with their documents' objects, and returns how many. */
    int purgeExpired(Instant now, ObjectStorage storage) {
        deleteObjects("m.expires_at <= ?", storage, Timestamp.from(now));
        return jdbc.sql("delete from inbound_message where expires_at <= ?").param(Timestamp.from(now)).update();
    }

    /** The storage keys of what is held for one member of a workspace. */
    List<String> objectKeysOf(UUID workspaceId, UUID userId) {
        return jdbc.sql("select d.object_key from inbound_document d join inbound_message m on m.id = d.message_id "
                        + "where d.object_key is not null and m.workspace_id = ? and m.user_id = ?")
                .params(workspaceId, userId).query(String.class).list();
    }

    /** Removes the records held for one member of a workspace. */
    int deleteMember(UUID workspaceId, UUID userId) {
        return jdbc.sql("delete from inbound_message where workspace_id = ? and user_id = ?")
                .params(workspaceId, userId).update();
    }

    long purgeWorkspace(UUID workspaceId) {
        return jdbc.sql("delete from inbound_message where workspace_id = ?").param(workspaceId).update();
    }

    /** A message still being handled long after it arrived failed permanently. */
    int failStuck(Instant before) {
        return jdbc.sql("update inbound_message set outcome = 'failed' where outcome = 'processing' "
                        + "and received_at < ?")
                .param(Timestamp.from(before)).update();
    }

    private void deleteObjects(String where, ObjectStorage storage, Object... params) {
        jdbc.sql("select d.object_key from inbound_document d join inbound_message m on m.id = d.message_id "
                        + "where d.object_key is not null and " + where)
                .params(params).query(String.class).list().forEach(storage::delete);
    }
}
