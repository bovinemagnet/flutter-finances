package com.paulsnow.finance.server.common;

import java.util.UUID;
import java.util.regex.Pattern;

import org.slf4j.MDC;

/**
 * Opaque correlation identifiers carried in the {@code X-Correlation-Id}
 * header and the logging context.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public final class CorrelationIds {

    /** Request and response header name. */
    public static final String HEADER = "X-Correlation-Id";

    /** Logging context key. */
    public static final String MDC_KEY = "correlationId";

    private static final Pattern VALID = Pattern.compile("[A-Za-z0-9-]{1,64}");

    private CorrelationIds() {
    }

    /** Returns the current identifier, or null outside a request or job. */
    public static String current() {
        return MDC.get(MDC_KEY);
    }

    /**
     * Returns {@code candidate} when it is a safe opaque identifier, otherwise
     * a new random one.
     *
     * @param candidate client-supplied value, possibly null
     * @return a safe identifier
     */
    public static String sanitise(String candidate) {
        return candidate != null && VALID.matcher(candidate).matches() ? candidate : UUID.randomUUID().toString();
    }

    /**
     * Runs {@code action} with a correlation identifier in the logging
     * context, for background jobs.
     *
     * @param id     identifier
     * @param action work to run
     */
    public static void runWith(String id, Runnable action) {
        String previous = MDC.get(MDC_KEY);
        MDC.put(MDC_KEY, sanitise(id));
        try {
            action.run();
        } finally {
            if (previous == null) {
                MDC.remove(MDC_KEY);
            } else {
                MDC.put(MDC_KEY, previous);
            }
        }
    }
}
