package com.paulsnow.finance.server.workspace;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;

import com.paulsnow.finance.core.ids.Ids;
import com.paulsnow.finance.server.support.IntegrationTestSupport;

/**
 * Workspace creation and bootstrap, membership scoping and device
 * registration and revocation.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class WorkspaceApiIntegrationTest extends IntegrationTestSupport {

    @Test
    void createsAWorkspaceWithAClientGeneratedIdAndBootstrapsIt() throws Exception {
        String subject = newSubject();
        UUID id = Ids.newUuid();
        mvc.perform(post("/v1/workspaces").with(user(subject)).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("id", id.toString(), "name", "Home",
                                "currency", "AUD", "timezone", "Australia/Perth"))))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(id.toString()))
                .andExpect(jsonPath("$.currency").value("AUD"))
                .andExpect(jsonPath("$.currencyExponent").value(2))
                .andExpect(jsonPath("$.timezone").value("Australia/Perth"))
                .andExpect(jsonPath("$.role").value("owner"));

        mvc.perform(get("/v1/workspaces/" + id).with(user(subject)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.schemaVersion").value(1))
                .andExpect(jsonPath("$.tombstoneHorizonDays").value(90))
                .andExpect(jsonPath("$.maxCommandsPerBatch").value(500))
                .andExpect(jsonPath("$.serverTime").isNotEmpty());

        mvc.perform(get("/v1/workspaces").with(user(subject)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].id").value(id.toString()));

        mvc.perform(post("/v1/workspaces").with(user(subject)).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("id", id.toString(), "name", "Again",
                                "currency", "AUD", "timezone", "Australia/Perth"))))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("WORKSPACE_EXISTS"));
    }

    @Test
    void rejectsUnknownCurrenciesAndTimezones() throws Exception {
        mvc.perform(post("/v1/workspaces").with(user(newSubject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("name", "Home", "currency", "XYZ",
                                "timezone", "Australia/Perth"))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_CURRENCY"));
        mvc.perform(post("/v1/workspaces").with(user(newSubject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("name", "Home", "currency", "AUD",
                                "timezone", "Mars/Olympus"))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_TIMEZONE"));
    }

    @Test
    void hidesWorkspacesFromNonMembers() throws Exception {
        Actor owner = newActor();
        String stranger = newSubject();
        mvc.perform(get("/v1/workspaces/" + owner.workspaceId()).with(user(stranger)))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("WORKSPACE_NOT_FOUND"));
        mvc.perform(post("/v1/devices").with(user(stranger)).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("deviceId", Ids.newId(),
                                "workspaceId", owner.workspaceId().toString(), "name", "x", "platform", "linux"))))
                .andExpect(status().isNotFound());
    }

    @Test
    void requiresARegisteredUnrevokedDeviceOfTheCallerForSync() throws Exception {
        Actor actor = newActor();
        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("DEVICE_REQUIRED"));

        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", UUID.randomUUID().toString()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error").value("DEVICE_NOT_AUTHORISED"));

        Actor other = newActor();
        mvc.perform(get("/v1/sync/changes").with(user(other.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error").value("DEVICE_NOT_AUTHORISED"));

        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()))
                .andExpect(status().isOk());

        mvc.perform(get("/v1/devices").with(user(actor.subject()))
                        .header("X-Workspace-Id", actor.workspaceId().toString()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].deviceId").value(actor.deviceId().toString()))
                .andExpect(jsonPath("$[0].revoked").value(false));

        mvc.perform(delete("/v1/devices/" + actor.deviceId()).with(user(actor.subject())))
                .andExpect(status().isNoContent());

        mvc.perform(get("/v1/sync/changes").with(user(actor.subject()))
                        .header("X-Device-Id", actor.deviceId().toString()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error").value("DEVICE_REVOKED"));

        mvc.perform(post("/v1/devices").with(user(actor.subject())).contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("deviceId", actor.deviceId().toString(),
                                "workspaceId", actor.workspaceId().toString(), "name", "x", "platform", "linux"))))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("DEVICE_REVOKED"));
    }

    @Test
    void doesNotLetAnotherUserRevokeADevice() throws Exception {
        Actor actor = newActor();
        mvc.perform(delete("/v1/devices/" + actor.deviceId()).with(user(newSubject())))
                .andExpect(status().isNotFound());
    }
}
