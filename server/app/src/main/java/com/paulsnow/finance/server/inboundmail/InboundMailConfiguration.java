package com.paulsnow.finance.server.inboundmail;

import java.time.Clock;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import tools.jackson.databind.json.JsonMapper;

/**
 * Wires the sandbox provider, only when configured. No real provider is
 * wired: choosing an inbound email service is a pending decision.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
class InboundMailConfiguration {

    @Bean
    @ConditionalOnProperty(name = "finance.inbound-mail.sandbox.enabled", havingValue = "true")
    InboundMailProvider sandboxInboundMailProvider(InboundMailProperties properties, Clock clock, JsonMapper json) {
        return new SandboxInboundMailProvider(properties.webhookSecrets().get("sandbox"),
                properties.webhookTolerance(), clock, json);
    }
}
