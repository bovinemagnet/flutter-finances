package com.paulsnow.finance.server.common;

import ch.qos.logback.classic.pattern.MessageConverter;
import ch.qos.logback.classic.spi.ILoggingEvent;

/**
 * Logback converter ({@code %redactedMessage}) that applies {@link Redactor}
 * to the formatted log message.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public class RedactingMessageConverter extends MessageConverter {

    @Override
    public String convert(ILoggingEvent event) {
        return Redactor.redact(super.convert(event));
    }
}
