package com.paulsnow.finance.server.audit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;

import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.support.HouseholdSupport;

import tools.jackson.databind.JsonNode;

/**
 * Audit events: recorded with the actions that cause them, minimised to
 * identifiers and codes, readable by owners only and purged after the
 * retention period.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class AuditIntegrationTest extends HouseholdSupport {

    @Autowired
    private AuditLog audit;

    @Test
    void recordsMinimisedEventsForMembershipDevicesAndExports() throws Exception {
        Actor owner = newActor();
        Actor member = join(owner, "member");
        mvc.perform(post("/v1/exports").with(user(owner.subject()))
                        .header("X-Workspace-Id", owner.workspaceId().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isAccepted());

        JsonNode events = events(owner);
        List<String> kinds = new ArrayList<>();
        events.path("events").forEach(e -> kinds.add(e.path("kind").asString()));
        assertThat(kinds).contains("device.registered", "invitation.created", "invitation.accepted",
                "member.joined", "export.requested");
        assertThat(events.toString()).doesNotContain("Household").doesNotContain("Test phone");

        mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/audit-events").with(user(member.subject())))
                .andExpect(status().isForbidden());
    }

    @Test
    void refusesContentThatIsNotAnIdentifierOrCode() {
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> new AuditEvent(null, null, "export.requested",
                "export", "Coffee $4.50", null)).isInstanceOf(IllegalArgumentException.class);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> new AuditEvent(null, null, "Paid the grocer",
                null, null, null)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void purgesEventsOlderThanTheRetentionPeriod() throws Exception {
        Actor owner = newActor();
        assertThat(events(owner).path("events").size()).isPositive();
        clock.advance(Duration.ofDays(366));
        audit.purgeExpired();
        clock.reset();
        assertThat(events(owner).path("events").size()).isZero();
    }

    private JsonNode events(Actor owner) throws Exception {
        return json.readTree(mvc.perform(get("/v1/workspaces/" + owner.workspaceId() + "/audit-events")
                        .with(user(owner.subject())))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
}
