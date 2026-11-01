package com.paulsnow.finance.server.sync;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;

import org.junit.jupiter.api.Test;

/**
 * Defaults applied to missing or non-positive sync settings.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class SyncPropertiesTest {

    @Test
    void missingWaitSettingsGetDefaults() {
        var properties = new SyncProperties(null, 0, 0, null, null);
        assertThat(properties.maxWait()).isEqualTo(Duration.ofSeconds(25));
        assertThat(properties.waitRecheck()).isEqualTo(Duration.ofSeconds(2));
    }

    @Test
    void zeroOrNegativeWaitSettingsGetDefaults() {
        var zero = new SyncProperties(null, 0, 0, Duration.ZERO, Duration.ZERO);
        var negative = new SyncProperties(null, 0, 0, Duration.ofSeconds(-1), Duration.ofMillis(-5));
        assertThat(zero.maxWait()).isEqualTo(Duration.ofSeconds(25));
        assertThat(zero.waitRecheck()).isEqualTo(Duration.ofSeconds(2));
        assertThat(negative.maxWait()).isEqualTo(Duration.ofSeconds(25));
        assertThat(negative.waitRecheck()).isEqualTo(Duration.ofSeconds(2));
    }

    @Test
    void positiveWaitSettingsAreKept() {
        var properties = new SyncProperties(null, 0, 0, Duration.ofSeconds(10), Duration.ofSeconds(1));
        assertThat(properties.maxWait()).isEqualTo(Duration.ofSeconds(10));
        assertThat(properties.waitRecheck()).isEqualTo(Duration.ofSeconds(1));
    }
}
