package com.paulsnow.finance.server.support;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Map;
import java.util.UUID;

import org.springframework.http.MediaType;

import tools.jackson.databind.JsonNode;

/**
 * Integration test support for shared households: invites a new user into
 * an owner's workspace and registers a device for them.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public abstract class HouseholdSupport extends IntegrationTestSupport {

    /** Creates an invitation as {@code owner} and returns the creation response. */
    protected JsonNode invite(Actor owner, String role) throws Exception {
        String response = mvc.perform(post("/v1/workspaces/" + owner.workspaceId() + "/invitations")
                        .with(user(owner.subject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("role", role))))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        return json.readTree(response);
    }

    /** Invites a new user with {@code role}, accepts, and registers a device for them. */
    protected Actor join(Actor owner, String role) throws Exception {
        JsonNode invitation = invite(owner, role);
        String subject = newSubject();
        mvc.perform(post("/v1/workspaces/" + owner.workspaceId() + "/invitations/"
                        + invitation.path("id").asString() + "/accept").with(user(subject))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("token", invitation.path("token").asString()))))
                .andExpect(status().isOk());
        UUID deviceId = registerDevice(subject, owner.workspaceId());
        return new Actor(subject, owner.workspaceId(), deviceId);
    }
}
