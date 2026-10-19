package com.paulsnow.finance.server.bankfeeds;

import java.time.Clock;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the token cipher and, only when configured, the sandbox provider.
 * No real provider is wired: choosing an Australian Consumer Data Right
 * provider and the participation model is a pending business decision
 * (BANK 01).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
class BankFeedsConfiguration {

    @Bean
    TokenCipher bankFeedTokenCipher(BankFeedProperties properties) {
        return new TokenCipher(properties.tokenKey());
    }

    @Bean
    @ConditionalOnProperty(name = "finance.bank-feeds.sandbox.enabled", havingValue = "true")
    BankFeedProvider sandboxBankFeedProvider(Clock clock) {
        return new SandboxBankFeedProvider(clock);
    }
}
