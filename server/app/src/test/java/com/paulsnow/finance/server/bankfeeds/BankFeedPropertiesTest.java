package com.paulsnow.finance.server.bankfeeds;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;

import org.junit.jupiter.api.Test;

/**
 * Refresh backoff settings.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class BankFeedPropertiesTest {

    @Test
    void backsOffExponentiallyWithinBounds() {
        BankFeedProperties properties = new BankFeedProperties(null, null, null, Duration.ofMinutes(1),
                Duration.ofMinutes(10), 0, null);
        assertThat(properties.backoff(1, Duration.ZERO)).isEqualTo(Duration.ofMinutes(1));
        assertThat(properties.backoff(2, Duration.ZERO)).isEqualTo(Duration.ofMinutes(2));
        assertThat(properties.backoff(3, Duration.ZERO)).isEqualTo(Duration.ofMinutes(4));
        assertThat(properties.backoff(3, Duration.ofMinutes(7))).isEqualTo(Duration.ofMinutes(7));
        assertThat(properties.backoff(30, Duration.ZERO)).isEqualTo(Duration.ofMinutes(10));
    }
}
