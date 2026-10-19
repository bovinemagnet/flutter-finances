package com.paulsnow.finance.core.ids;

import java.security.SecureRandom;
import java.util.UUID;

/**
 * Generates UUIDv7 identifiers, matching the client's offline identifiers.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class Ids {

    private static final SecureRandom RANDOM = new SecureRandom();

    private static long lastMillis = -1;
    private static int sequence;

    private Ids() {
    }

    /**
     * Returns a new UUIDv7. The leading 48 bits are the Unix time in
     * milliseconds; within one millisecond a 12-bit counter keeps identifiers
     * from this process ordered.
     *
     * @return a version 7 UUID
     */
    public static synchronized UUID newUuid() {
        long millis = System.currentTimeMillis();
        if (millis <= lastMillis) {
            sequence++;
            if (sequence > 0xfff) {
                lastMillis++;
                sequence = 0;
            }
            millis = lastMillis;
        } else {
            lastMillis = millis;
            sequence = RANDOM.nextInt(0x400);
        }
        long high = (millis << 16) | 0x7000L | sequence;
        long low = (RANDOM.nextLong() & 0x3fffffffffffffffL) | 0x8000000000000000L;
        return new UUID(high, low);
    }

    /** Returns {@link #newUuid()} as a string. */
    public static String newId() {
        return newUuid().toString();
    }
}
