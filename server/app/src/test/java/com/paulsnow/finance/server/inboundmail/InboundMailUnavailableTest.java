package com.paulsnow.finance.server.inboundmail;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;

import com.paulsnow.finance.server.support.IntegrationTestSupport;

/**
 * With no provider configured the feature reports itself unavailable, and
 * no address can be created.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class InboundMailUnavailableTest extends IntegrationTestSupport {

    @Test
    void statusIsUnavailableWithoutAProvider() throws Exception {
        Actor actor = newActor();
        mvc.perform(get("/v1/inbound-mail/status").with(user(actor.subject())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.available").value(false));
    }

    @Test
    void addressesCannotBeCreatedWithoutAProvider() throws Exception {
        Actor actor = newActor();
        mvc.perform(put("/v1/workspaces/" + actor.workspaceId() + "/inbound-address").with(user(actor.subject())))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("INBOUND_MAIL_UNAVAILABLE"));
    }
}
