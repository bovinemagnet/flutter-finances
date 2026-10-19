package com.paulsnow.finance.server.support;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

/**
 * A clock tests can move forward, for example past the tombstone horizon.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class MutableClock extends Clock {

    private volatile Duration offset = Duration.ZERO;

    /** Moves the clock forward by {@code amount}. */
    public void advance(Duration amount) {
        offset = offset.plus(amount);
    }

    /** Returns the clock to real time. */
    public void reset() {
        offset = Duration.ZERO;
    }

    @Override
    public ZoneId getZone() {
        return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
        return this;
    }

    @Override
    public Instant instant() {
        return Instant.now().plus(offset);
    }
}
