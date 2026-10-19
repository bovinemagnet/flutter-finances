package com.paulsnow.finance.server.households;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.HouseholdSupport;

import tools.jackson.databind.JsonNode;

/**
 * Shared households: invitations, roles, member removal and the visibility
 * of private and shared accounts in the change feed, snapshot and commands.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class HouseholdsIntegrationTest extends HouseholdSupport {

    @Test
    void anotherUserJoinsWithAnInvitationExactlyOnce() throws Exception {
        Actor owner = newActor();
        JsonNode invitation = invite(owner, "member");
        assertThat(invitation.path("token").asString()).hasSizeGreaterThan(40);
        assertThat(invitation.path("status").asString()).isEqualTo("pending");
        String url = "/v1/workspaces/" + owner.workspaceId() + "/invitations/" + invitation.path("id").asString();
        String token = invitation.path("token").asString();

        String guest = newSubject();
        mvc.perform(post(url + "/accept").with(user(guest)).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", "wrong"))))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("INVITATION_NOT_FOUND"));
        mvc.perform(post(url + "/accept").with(user(guest)).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", token))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.workspaceId").value(owner.workspaceId().toString()))
                .andExpect(jsonPath("$.role").value("member"));
        mvc.perform(post(url + "/accept").with(user(newSubject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", token))))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("INVITATION_USED"));

        mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/members").with(user(guest)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(2))
                .andExpect(jsonPath("$[0].role").value("owner"))
                .andExpect(jsonPath("$[1].role").value("member"))
                .andExpect(jsonPath("$[1].you").value(true));
        mvc.perform(get("/v1/workspaces").with(user(guest)))
                .andExpect(jsonPath("$[0].role").value("member"));
        // Members cannot invite or list invitations.
        mvc.perform(post("/v1/workspaces/" + owner.workspaceId() + "/invitations").with(user(guest))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("role", "viewer"))))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("OWNER_REQUIRED"));
        mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/invitations").with(user(owner.subject())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].status").value("accepted"))
                .andExpect(jsonPath("$[0].token").doesNotExist());
    }

    @Test
    void revokedAndExpiredInvitationsCannotBeAccepted() throws Exception {
        Actor owner = newActor();
        JsonNode revoked = invite(owner, "viewer");
        String base = "/v1/workspaces/" + owner.workspaceId() + "/invitations/";
        mvc.perform(delete(base + revoked.path("id").asString()).with(user(owner.subject())))
                .andExpect(status().isNoContent());
        mvc.perform(post(base + revoked.path("id").asString() + "/accept").with(user(newSubject()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", revoked.path("token").asString()))))
                .andExpect(status().isGone()).andExpect(jsonPath("$.error").value("INVITATION_REVOKED"));

        JsonNode expiring = invite(owner, "member");
        clock.advance(Duration.ofHours(73));
        mvc.perform(post(base + expiring.path("id").asString() + "/accept").with(user(newSubject()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", expiring.path("token").asString()))))
                .andExpect(status().isGone()).andExpect(jsonPath("$.error").value("INVITATION_EXPIRED"));

        mvc.perform(post("/v1/workspaces/" + owner.workspaceId() + "/invitations").with(user(owner.subject()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("role", "owner"))))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("INVALID_ROLE"));
    }

    @Test
    void viewersReadButEveryCommandIsDenied() throws Exception {
        Actor owner = newActor();
        String shared = sharedAccount(owner);
        Actor viewer = join(owner, "viewer");

        JsonNode result = submitOne(viewer, upsert(viewer, "account", shared, 1, Map.of("name", "Renamed")));
        assertThat(result.path("status").asString()).isEqualTo("permission_denied");
        assertThat(result.path("errors").get(0).asString()).isEqualTo("NOT_PERMITTED");
        assertThat(ids(changes(viewer, "")).contains(shared)).isTrue();

        mvc.perform(post("/v1/imports/preview").with(user(viewer.subject()))
                        .header("X-Device-Id", viewer.deviceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("READ_ONLY"));
    }

    @Test
    void membersSeeSharedAccountsCategoriesAndTheirJournalsOnly() throws Exception {
        Actor owner = newActor();
        String category = createCategory(owner, "expense");
        String privateAccount = createAccount(owner, "transaction");
        String shared = sharedAccount(owner);
        String privateJournal = Ids.newId();
        String sharedJournal = Ids.newId();
        submit(owner, postJournal(owner, expenseJournal(privateJournal, privateAccount, category, 1000, "posted"), 0),
                postJournal(owner, expenseJournal(sharedJournal, shared, category, 2000, "posted"), 0));
        String sharedNote = Ids.newId();
        String privateNote = Ids.newId();
        submit(owner, upsert(owner, "journalAnnotation", sharedNote, 0, Map.of("journalId", sharedJournal)),
                upsert(owner, "journalAnnotation", privateNote, 0, Map.of("journalId", privateJournal)),
                upsert(owner, "budgetPlan", Ids.newId(), 0, Map.of("name", "Plan")));

        Actor member = join(owner, "member");
        List<String> seen = ids(changes(member, ""));
        assertThat(seen).contains(category, shared, sharedJournal, sharedNote)
                .doesNotContain(privateAccount, privateJournal, privateNote);
        assertThat(snapshotIds(member)).contains(category, shared, sharedJournal, sharedNote)
                .doesNotContain(privateAccount, privateJournal, privateNote);
        // The owner still sees everything.
        assertThat(ids(changes(owner, ""))).contains(privateAccount, privateJournal, privateNote);

        // A member cannot touch or post to an account that is private to the owner.
        JsonNode rename = submitOne(member, upsert(member, "account", privateAccount, 1, Map.of("name", "Mine")));
        assertThat(rename.path("status").asString()).isEqualTo("permission_denied");
        JsonNode post = submitOne(member, postJournal(member,
                expenseJournal(Ids.newId(), privateAccount, category, 500, "posted"), 0));
        assertThat(post.path("errors").toString()).contains("UNKNOWN_LEDGER_ACCOUNT");
        JsonNode share = submitOne(member, upsert(member, "account", shared, 2, Map.of("sharing", "private")));
        assertThat(share.path("status").asString()).isEqualTo("permission_denied");
        // But may use the shared one.
        JsonNode own = submitOne(member, postJournal(member,
                expenseJournal(Ids.newId(), shared, category, 300, "posted"), 0));
        assertThat(own.path("status").asString()).isEqualTo("applied");
    }

    @Test
    void sharingAndUnsharingAnAccountMovesItAndItsJournalsInAndOutOfAMembersFeed() throws Exception {
        Actor owner = newActor();
        String category = createCategory(owner, "expense");
        String account = createAccount(owner, "transaction");
        String journal = Ids.newId();
        submitOne(owner, postJournal(owner, expenseJournal(journal, account, category, 1000, "posted"), 0));
        Actor member = join(owner, "member");
        JsonNode first = changes(member, "");
        assertThat(ids(first)).doesNotContain(account, journal);

        submitOne(owner, upsert(owner, "account", account, 1, Map.of("sharing", "shared")));
        JsonNode second = changes(member, first.path("cursor").asString());
        assertThat(ops(second, account)).containsExactly("upsert");
        assertThat(ops(second, journal)).containsExactly("upsert");

        submitOne(owner, upsert(owner, "account", account, 2, Map.of("sharing", "private")));
        JsonNode third = changes(member, second.path("cursor").asString());
        assertThat(ops(third, account)).containsExactly("delete");
        assertThat(ops(third, journal)).containsExactly("delete");
        // The creator keeps receiving upserts.
        assertThat(ops(changes(owner, ""), account)).doesNotContain("delete");
    }

    @Test
    void removingAMemberRevokesTheirDevicesAndTheLastOwnerStays() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        UUID memberId = userIdOf(member);
        UUID ownerId = userIdOf(owner);
        String members = "/v1/workspaces/" + owner.workspaceId() + "/members/";

        mvc.perform(delete(members + ownerId).with(user(owner.subject())))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("LAST_OWNER"));
        mvc.perform(delete(members + ownerId).with(user(member.subject())))
                .andExpect(status().isForbidden());
        mvc.perform(patch(members + memberId).with(user(owner.subject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("role", "viewer"))))
                .andExpect(status().isNoContent());
        mvc.perform(get("/v1/workspaces").with(user(member.subject())))
                .andExpect(jsonPath("$[0].role").value("viewer"));

        mvc.perform(delete(members + memberId).with(user(owner.subject()))).andExpect(status().isNoContent());
        mvc.perform(get("/v1/sync/changes").with(user(member.subject()))
                        .header("X-Device-Id", member.deviceId().toString()))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.error").value("DEVICE_REVOKED"));
        mvc.perform(get("/v1/workspaces/" + owner.workspaceId()).with(user(member.subject())))
                .andExpect(status().isNotFound());
    }

    private String sharedAccount(Actor owner) throws Exception {
        String id = Ids.newId();
        JsonNode result = submitOne(owner, upsert(owner, "account", id, 0,
                Map.of("name", "Joint", "type", "transaction", "sharing", "shared")));
        assertThat(result.path("status").asString()).isEqualTo("applied");
        return id;
    }

    private UUID userIdOf(Actor actor) throws Exception {
        JsonNode list = json.readTree(mvc.perform(get("/v1/workspaces/" + actor.workspaceId() + "/members")
                .with(user(actor.subject()))).andReturn().getResponse().getContentAsString());
        for (JsonNode member : list) {
            if (member.path("you").asBoolean()) {
                return UUID.fromString(member.path("userId").asString());
            }
        }
        throw new AssertionError("caller not listed");
    }

    private List<String> snapshotIds(Actor actor) throws Exception {
        JsonNode page = json.readTree(mvc.perform(get("/v1/sync/snapshot").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        return ids(page);
    }

    private static List<String> ids(JsonNode page) {
        List<String> ids = new ArrayList<>();
        page.path("changes").forEach(c -> ids.add(c.path("entityId").asString()));
        return ids;
    }

    private static List<String> ops(JsonNode page, String entityId) {
        List<String> ops = new ArrayList<>();
        page.path("changes").forEach(c -> {
            if (c.path("entityId").asString().equals(entityId)) {
                ops.add(c.path("op").asString());
            }
        });
        return ops;
    }
}
