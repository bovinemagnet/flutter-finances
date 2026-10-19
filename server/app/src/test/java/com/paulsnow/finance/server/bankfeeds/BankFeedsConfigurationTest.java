package com.paulsnow.finance.server.bankfeeds;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;

import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The sandbox provider exists only when configuration enables it, and no
 * other provider is wired by default.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class BankFeedsConfigurationTest {

    @Configuration(proxyBeanMethods = false)
    @EnableConfigurationProperties(BankFeedProperties.class)
    static class Base {

        @Bean
        Clock clock() {
            return Clock.systemUTC();
        }
    }

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withUserConfiguration(Base.class, BankFeedsConfiguration.class);

    @Test
    void noProviderIsWiredByDefault() {
        runner.run(context -> assertThat(context).doesNotHaveBean(BankFeedProvider.class));
    }

    @Test
    void theSandboxIsWiredOnlyWhenEnabled() {
        runner.withPropertyValues("finance.bank-feeds.sandbox.enabled=true").run(context -> {
            assertThat(context).hasSingleBean(BankFeedProvider.class);
            assertThat(context.getBean(BankFeedProvider.class).id()).isEqualTo("sandbox");
        });
    }
}
