package com.paulsnow.finance.server.sync;

import java.util.List;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.deletion.WorkspaceDataPurger;

/**
 * Removes the entity store, change log, idempotency records and cursors of
 * a deleted workspace.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class SyncPurger implements WorkspaceDataPurger {

    private static final List<String> TABLES = List.of("sync_entity", "sync_change", "sync_idempotency",
            "sync_device_cursor", "sync_purge_watermark");

    private final JdbcClient jdbc;

    SyncPurger(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public String step() {
        return "sync";
    }

    @Override
    public long purge(UUID workspaceId) {
        long removed = 0;
        for (String table : TABLES) {
            removed += jdbc.sql("delete from " + table + " where workspace_id = ?").param(workspaceId).update();
        }
        return removed;
    }
}
