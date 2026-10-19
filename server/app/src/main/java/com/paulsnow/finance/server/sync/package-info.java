/**
 * The sync protocol ({@code spec/sync/protocol.md}): command intake with
 * idempotency records, the entity store with per-entity and per-field
 * revisions, the ordered change log, tombstones, the change feed with
 * opaque cursors and paged snapshots.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@org.springframework.modulith.ApplicationModule(displayName = "Sync")
package com.paulsnow.finance.server.sync;
