package com.paulsnow.finance.server.sync;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import com.paulsnow.finance.server.ledger.LedgerService;

/**
 * Computes {@link Visibility} for a member, for the change feed, snapshots,
 * commands, reports and exports.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Service
public class VisibilityService {

    private final JdbcClient jdbc;
    private final LedgerService ledger;

    VisibilityService(JdbcClient jdbc, LedgerService ledger) {
        this.jdbc = jdbc;
        this.ledger = ledger;
    }

    /**
     * Returns what {@code userId} may see in a workspace.
     *
     * @param workspaceId workspace
     * @param userId      member, or null for server-originated work (sees everything)
     * @return the visibility
     */
    public Visibility forMember(UUID workspaceId, UUID userId) {
        if (userId == null) {
            return Visibility.everything();
        }
        Set<String> hidden = new LinkedHashSet<>();
        jdbc.sql("select entity_id from sync_entity where workspace_id = ? and entity_type = 'account' "
                        + "and not deleted and created_by is not null and created_by <> ? "
                        + "and coalesce(data ->> 'sharing', 'private') <> 'shared'")
                .params(workspaceId, userId).query(UUID.class).list()
                .forEach(id -> hidden.add(id.toString()));
        if (hidden.isEmpty()) {
            return Visibility.everything();
        }
        return new Visibility(hidden, journalId -> {
            try {
                return ledger.accountsOf(workspaceId, UUID.fromString(journalId));
            } catch (IllegalArgumentException e) {
                return Set.of();
            }
        });
    }
}
