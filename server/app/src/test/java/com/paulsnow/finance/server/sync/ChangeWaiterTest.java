package com.paulsnow.finance.server.sync;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;

import org.junit.jupiter.api.Test;

/**
 * How a requested long-poll wait is capped (NFR 05).
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class ChangeWaiterTest {

    private static final Duration MAX = Duration.ofSeconds(25);

    @Test
    void noRequestedWaitMeansNoWait() {
        assertThat(ChangeWaiter.effectiveWait(null, MAX)).isEqualTo(Duration.ZERO);
        assertThat(ChangeWaiter.effectiveWait(0, MAX)).isEqualTo(Duration.ZERO);
        assertThat(ChangeWaiter.effectiveWait(-3, MAX)).isEqualTo(Duration.ZERO);
    }

    @Test
    void theWaitIsCappedAtTheMaximum() {
        assertThat(ChangeWaiter.effectiveWait(10, MAX)).isEqualTo(Duration.ofSeconds(10));
        assertThat(ChangeWaiter.effectiveWait(600, MAX)).isEqualTo(MAX);
    }
}
