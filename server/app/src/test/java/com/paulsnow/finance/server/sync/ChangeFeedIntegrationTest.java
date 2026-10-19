package com.paulsnow.finance.server.sync;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

import tools.jackson.databind.JsonNode;

/**
 * Change feed paging, cursor expiry after the tombstone horizon, snapshot
 * rebuild and protection against resurrecting deleted records (SYNC 04,
 * SYNC 06, A15).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ChangeFeedIntegrationTest extends IntegrationTestSupport {

    @Autowired
    TombstonePurger purger;

    @Test
    void pagesChangesInOrderWithAnOpaqueCursor() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        List<String> ids = new ArrayList<>();
        for (int i = 0; i < 5; i++) {
            ids.add(createAccount(phone, "transaction"));
        }

        JsonNode first = changes(tablet, null, 2);
        assertThat(first.path("changes")).hasSize(2);
        assertThat(first.path("hasMore").asBoolean()).isTrue();
        JsonNode second = changes(tablet, first.path("cursor").asString(), 2);
        JsonNode third = changes(tablet, second.path("cursor").asString(), 2);
        assertThat(third.path("hasMore").asBoolean()).isFalse();

        List<String> seen = new ArrayList<>();
        for (JsonNode page : List.of(first, second, third)) {
            for (JsonNode change : page.path("changes")) {
                seen.add(change.path("entityId").asString());
                assertThat(change.path("entityType").asString()).isEqualTo("account");
                assertThat(change.path("op").asString()).isEqualTo("upsert");
                assertThat(change.path("revision").asLong()).isEqualTo(1);
                assertThat(change.path("data").path("id").asString()).isEqualTo(change.path("entityId").asString());
            }
        }
        assertThat(seen).containsExactlyElementsOf(ids);

        JsonNode caughtUp = changes(tablet, third.path("cursor").asString(), 2);
        assertThat(caughtUp.path("changes")).isEmpty();
        assertThat(caughtUp.path("hasMore").asBoolean()).isFalse();
    }

    @Test
    void rejectsCursorsFromAnotherWorkspaceOrThatAreMalformed() throws Exception {
        Actor actor = newActor();
        Actor other = newActor();
        createAccount(other, "cash");
        String foreignCursor = changes(other, null).path("cursor").asString();
        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()).param("cursor", foreignCursor))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("INVALID_CURSOR"));
        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()).param("cursor", "not-a-cursor"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("INVALID_CURSOR"));
    }

    @Test
    void a15ExpiredCursorGets410AndSnapshotRebasePreventsResurrection() throws Exception {
        Actor oldDevice = newActor();
        Actor activeDevice = secondDevice(oldDevice);
        String kept = createAccount(oldDevice, "transaction");
        String doomed = createAccount(oldDevice, "savings");
        String staleCursor = changes(oldDevice, null).path("cursor").asString();

        // While the old device is away, another device deletes an account.
        JsonNode deletion = submitOne(activeDevice, command(activeDevice, "entity.delete", "account", doomed, 1,
                json.createObjectNode()));
        assertThat(deletion.path("status").asString()).isEqualTo("applied");

        clock.advance(Duration.ofDays(91));
        purger.purgeExpiredTombstones();

        mvc.perform(get("/v1/sync/changes").with(user(oldDevice.subject()))
                        .header("X-Device-Id", oldDevice.deviceId().toString()).param("cursor", staleCursor))
                .andExpect(status().isGone())
                .andExpect(jsonPath("$.error").value("CURSOR_EXPIRED"));

        // Snapshot rebuild: only live entities, paged by entity key.
        Set<String> snapshotIds = new HashSet<>();
        String after = "";
        String snapshotCursor = null;
        boolean more = true;
        while (more) {
            JsonNode page = json.readTree(mvc.perform(get("/v1/sync/snapshot").with(user(oldDevice.subject()))
                            .header("X-Device-Id", oldDevice.deviceId().toString())
                            .param("after", after).param("limit", "1"))
                    .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
            if (snapshotCursor == null) {
                snapshotCursor = page.path("cursor").asString();
            }
            for (JsonNode entity : page.path("entities")) {
                snapshotIds.add(entity.path("entityId").asString());
                assertThat(entity.path("data").isObject()).isTrue();
            }
            more = page.path("hasMore").asBoolean();
            after = page.path("after").asString();
        }
        assertThat(snapshotIds).containsExactly(kept);

        // The old device's pending edit of the deleted account is surfaced as
        // a conflict and never recreates it.
        JsonNode pendingEdit = submitOne(oldDevice, upsert(oldDevice, "account", doomed, 1,
                Map.of("name", "Renamed offline")));
        assertThat(pendingEdit.path("status").asString()).isEqualTo("conflict");
        assertThat(pendingEdit.path("errors").get(0).asString()).isEqualTo("ENTITY_DELETED");
        assertThat(pendingEdit.path("conflict").path("serverState").isNull()).isTrue();

        JsonNode recreate = submitOne(oldDevice, upsert(oldDevice, "account", doomed, 0,
                Map.of("name", "Again", "type", "savings")));
        assertThat(recreate.path("status").asString()).isEqualTo("conflict");

        // The cursor from the snapshot continues the feed.
        JsonNode resumed = changes(oldDevice, snapshotCursor);
        for (JsonNode change : resumed.path("changes")) {
            assertThat(change.path("entityId").asString()).isNotEqualTo(doomed);
        }
    }

    @Test
    void anEmptyCursorStillRebuildsAfterTombstonesArePurged() throws Exception {
        Actor actor = newActor();
        String kept = createAccount(actor, "transaction");
        String doomed = createAccount(actor, "cash");
        submitOne(actor, command(actor, "entity.delete", "account", doomed, 1, json.createObjectNode()));
        clock.advance(Duration.ofDays(91));
        purger.purgeExpiredTombstones();

        String later = createAccount(actor, "savings");

        // A full rebuild pages through the compacted log without expiring.
        Set<String> live = new HashSet<>();
        String cursor = null;
        boolean more = true;
        while (more) {
            JsonNode page = changes(actor, cursor, 1);
            for (JsonNode change : page.path("changes")) {
                live.add(change.path("entityId").asString());
            }
            cursor = page.path("cursor").asString();
            more = page.path("hasMore").asBoolean();
        }
        assertThat(live).contains(kept, later).doesNotContain(doomed);
    }

    @Test
    void deliversDeletionsAsTombstonesWithinTheHorizon() throws Exception {
        Actor phone = newActor();
        Actor tablet = secondDevice(phone);
        String id = createAccount(phone, "cash");
        String cursor = changes(tablet, null).path("cursor").asString();
        submitOne(phone, command(phone, "entity.delete", "account", id, 1, json.createObjectNode()));
        JsonNode feed = changes(tablet, cursor);
        assertThat(feed.path("changes")).hasSize(1);
        assertThat(feed.path("changes").get(0).path("op").asString()).isEqualTo("delete");
        assertThat(feed.path("changes").get(0).path("revision").asLong()).isEqualTo(2);
        assertThat(feed.path("changes").get(0).path("entityId").asString()).isEqualTo(id);
        Ids.newId();
    }

    private JsonNode changes(Actor actor, String cursor, int limit) throws Exception {
        return json.readTree(mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString())
                        .param("cursor", cursor == null ? "" : cursor).param("limit", String.valueOf(limit)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
}
