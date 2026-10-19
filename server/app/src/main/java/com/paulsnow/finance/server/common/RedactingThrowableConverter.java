package com.paulsnow.finance.server.common;

import ch.qos.logback.classic.pattern.ExtendedThrowableProxyConverter;
import ch.qos.logback.classic.spi.ILoggingEvent;

/**
 * Logback converter ({@code %redactedException}) that applies
 * {@link Redactor} to stack traces, whose messages can echo SQL parameters
 * or request data.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class RedactingThrowableConverter extends ExtendedThrowableProxyConverter {

    @Override
    public String convert(ILoggingEvent event) {
        return Redactor.redact(super.convert(event));
    }
}
