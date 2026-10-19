package com.paulsnow.finance.server.bankfeeds;

import java.sql.Date;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.bankfeeds.BankFeedProvider.ProviderTransaction;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.sync.EntityReader;

import tools.jackson.databind.json.JsonMapper;

/**
 * Turns provider transactions into provider records and import proposals
 * (BANK 03). Records are kept apart from canonical journals and nothing is
 * ever posted from here; the client posts a journal itself after the user
 * accepts a proposal. Every case is handled explicitly and idempotently:
 * <ul>
 * <li>the same provider id again updates a pending record and is otherwise ignored;</li>
 * <li>an id change ({@code previousId}) renames the existing record and keeps the old id;
 * a late delivery under the old id is ignored;</li>
 * <li>a posted transaction that settles a pending one is a new record linked both
 * ways; an open pending proposal is superseded, an accepted one keeps its journal
 * so the client settles that entry instead of adding a second purchase;</li>
 * <li>a reversal is a new record linked both ways to the transaction it reverses.</li>
 * </ul>
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class RecordReconciler {

    /** A provider record as an import proposal. */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    record Proposal(UUID recordId, String accountId, String providerTransactionId,
            List<String> previousProviderTransactionIds, String status, long amountMinor, String currency,
            LocalDate date, String description, String kind, UUID relatedRecordId, UUID settledByRecordId,
            UUID reversedByRecordId, String proposalStatus, UUID journalId, Instant firstSeenAt) {
    }

    private record Existing(UUID id, String status, String providerTransactionId, String proposalStatus) {
    }

    private final JdbcClient jdbc;
    private final JsonMapper json;
    private final Clock clock;
    private final EntityReader entities;
    private final ConnectionStore store;

    RecordReconciler(JdbcClient jdbc, JsonMapper json, Clock clock, EntityReader entities, ConnectionStore store) {
        this.jdbc = jdbc;
        this.json = json;
        this.clock = clock;
        this.entities = entities;
        this.store = store;
    }

    /**
     * Applies one page of an account's transactions and saves the account's
     * cursor in the same transaction. The connection row is locked first, so
     * nothing is collected once a revocation or expiry has committed.
     *
     * @return false, changing nothing, when the connection no longer collects
     */
    @Transactional
    boolean applyPage(ConnectionStore.Connection connection, String accountId, List<ProviderTransaction> page,
            String nextCursor) {
        boolean collecting = jdbc.sql("select consent_status from bank_feed_connection where id = ? for share")
                .param(connection.id()).query(String.class).optional().filter("active"::equals).isPresent();
        if (!collecting) {
            return false;
        }
        for (ProviderTransaction transaction : page) {
            apply(connection, accountId, transaction);
        }
        store.saveCursor(connection.id(), accountId, nextCursor);
        return true;
    }

    private void apply(ConnectionStore.Connection connection, String accountId, ProviderTransaction t) {
        Timestamp now = Timestamp.from(clock.instant());
        Optional<Existing> current = byProviderId(connection.id(), accountId, t.id());
        if (current.isEmpty() && byPreviousId(connection.id(), accountId, t.id()).isPresent()) {
            return; // A late delivery under an id the provider has since replaced.
        }
        if (current.isEmpty() && t.previousId() != null) {
            Optional<Existing> renamed = byProviderId(connection.id(), accountId, t.previousId());
            if (renamed.isPresent()) {
                jdbc.sql("update bank_feed_record set provider_transaction_id = ?, previous_provider_ids = "
                                + "previous_provider_ids || jsonb_build_array(?::text), updated_at = ? where id = ?")
                        .params(t.id(), t.previousId(), now, renamed.get().id()).update();
                current = byProviderId(connection.id(), accountId, t.id());
            }
        }
        if (current.isPresent()) {
            if ("pending".equals(current.get().status())) {
                jdbc.sql("update bank_feed_record set status = ?, amount_minor = ?, transaction_date = ?, "
                                + "description = ?, updated_at = ? where id = ?")
                        .params(status(t), t.amountMinor(), Date.valueOf(t.date()), t.description(), now,
                                current.get().id())
                        .update();
            }
            return;
        }
        UUID id = Ids.newUuid();
        jdbc.sql("insert into bank_feed_record (id, workspace_id, connection_id, provider_account_id, "
                        + "provider_transaction_id, previous_provider_ids, status, amount_minor, currency, "
                        + "transaction_date, description, proposal_status, first_seen_at, updated_at) "
                        + "values (?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?, 'open', ?, ?)")
                .params(id, connection.workspaceId(), connection.id(), accountId, t.id(),
                        t.previousId() == null ? "[]" : json.writeValueAsString(List.of(t.previousId())), status(t),
                        t.amountMinor(), t.currency(), Date.valueOf(t.date()), t.description(), now, now)
                .update();
        if (t.pendingId() != null) {
            lookup(connection.id(), accountId, t.pendingId()).ifPresent(pending -> {
                jdbc.sql("update bank_feed_record set pending_record_id = ? where id = ?").params(pending.id(), id)
                        .update();
                jdbc.sql("update bank_feed_record set settled_by_record_id = ?, proposal_status = case "
                                + "when proposal_status = 'open' then 'superseded' else proposal_status end, "
                                + "updated_at = ? where id = ?")
                        .params(id, now, pending.id()).update();
            });
        }
        if (t.reversalOf() != null) {
            lookup(connection.id(), accountId, t.reversalOf()).ifPresent(original -> {
                jdbc.sql("update bank_feed_record set reversal_of_record_id = ? where id = ?")
                        .params(original.id(), id).update();
                jdbc.sql("update bank_feed_record set reversed_by_record_id = ?, updated_at = ? where id = ?")
                        .params(id, now, original.id()).update();
            });
        }
    }

    /**
     * Lists a connection's proposals.
     *
     * @param status {@code open} (default), {@code all}, or one proposal status
     */
    List<Proposal> proposals(ConnectionStore.Connection connection, String status) {
        String filter = status == null || status.isBlank() ? "open" : status;
        if (!List.of("open", "all", "superseded", "accepted", "dismissed").contains(filter)) {
            throw ApiException.badRequest("INVALID_STATUS", "status must be open, all, superseded, accepted or "
                    + "dismissed.");
        }
        return jdbc.sql("select * from bank_feed_record where connection_id = ? and workspace_id = ? "
                        + "and (? = 'all' or proposal_status = ?) order by transaction_date, first_seen_at, id")
                .params(connection.id(), connection.workspaceId(), filter, filter).query(this::map).list();
    }

    /**
     * Records the user's decision on an open proposal. Accepting names the
     * journal the client posted itself, for provenance; nothing is posted
     * here.
     */
    @Transactional
    Proposal decide(ConnectionStore.Connection connection, UUID recordId, String decision, UUID journalId,
            UUID userId) {
        if (!"accepted".equals(decision) && !"dismissed".equals(decision)) {
            throw ApiException.badRequest("INVALID_DECISION", "decision must be accepted or dismissed.");
        }
        Proposal proposal = jdbc.sql("select * from bank_feed_record where id = ? and connection_id = ? "
                        + "and workspace_id = ? for update")
                .params(recordId, connection.id(), connection.workspaceId()).query(this::map).optional()
                .orElseThrow(() -> ApiException.notFound("PROPOSAL_NOT_FOUND", "Proposal not found."));
        if (!"open".equals(proposal.proposalStatus())) {
            throw ApiException.conflict("PROPOSAL_DECIDED", "This proposal was already decided or superseded.");
        }
        if (journalId != null && (!"accepted".equals(decision)
                || !entities.isLive(connection.workspaceId(), "journal", journalId))) {
            throw ApiException.badRequest("JOURNAL_NOT_FOUND", "Name a journal of this workspace when accepting.");
        }
        Timestamp now = Timestamp.from(clock.instant());
        jdbc.sql("update bank_feed_record set proposal_status = ?, journal_id = ?, decided_by = ?, decided_at = ?, "
                        + "updated_at = ? where id = ?")
                .params(decision, journalId, userId, now, now, recordId).update();
        return jdbc.sql("select * from bank_feed_record where id = ?").param(recordId).query(this::map).single();
    }

    private Optional<Existing> lookup(UUID connectionId, String accountId, String providerId) {
        Optional<Existing> found = byProviderId(connectionId, accountId, providerId);
        return found.isPresent() ? found : byPreviousId(connectionId, accountId, providerId);
    }

    private Optional<Existing> byProviderId(UUID connectionId, String accountId, String providerId) {
        return jdbc.sql("select id, status, provider_transaction_id, proposal_status from bank_feed_record "
                        + "where connection_id = ? and provider_account_id = ? and provider_transaction_id = ? "
                        + "for update")
                .params(connectionId, accountId, providerId).query(RecordReconciler::existing).optional();
    }

    private Optional<Existing> byPreviousId(UUID connectionId, String accountId, String providerId) {
        return jdbc.sql("select id, status, provider_transaction_id, proposal_status from bank_feed_record "
                        + "where connection_id = ? and provider_account_id = ? "
                        + "and previous_provider_ids @> jsonb_build_array(?::text) limit 1")
                .params(connectionId, accountId, providerId).query(RecordReconciler::existing).optional();
    }

    private static String status(ProviderTransaction t) {
        return "pending".equals(t.status()) ? "pending" : "posted";
    }

    private static Existing existing(ResultSet rs, int row) throws SQLException {
        return new Existing(rs.getObject("id", UUID.class), rs.getString("status"),
                rs.getString("provider_transaction_id"), rs.getString("proposal_status"));
    }

    private Proposal map(ResultSet rs, int row) throws SQLException {
        List<String> previous = new ArrayList<>();
        json.readTree(rs.getString("previous_provider_ids")).forEach(p -> previous.add(p.asString()));
        UUID pending = rs.getObject("pending_record_id", UUID.class);
        UUID reversalOf = rs.getObject("reversal_of_record_id", UUID.class);
        String kind = reversalOf != null ? "reversal" : pending != null ? "settles_pending" : "new";
        return new Proposal(rs.getObject("id", UUID.class), rs.getString("provider_account_id"),
                rs.getString("provider_transaction_id"), previous, rs.getString("status"), rs.getLong("amount_minor"),
                rs.getString("currency").trim(), rs.getDate("transaction_date").toLocalDate(),
                rs.getString("description"), kind, reversalOf != null ? reversalOf : pending,
                rs.getObject("settled_by_record_id", UUID.class), rs.getObject("reversed_by_record_id", UUID.class),
                rs.getString("proposal_status"), rs.getObject("journal_id", UUID.class),
                ConnectionStore.instant(rs, "first_seen_at"));
    }
}
