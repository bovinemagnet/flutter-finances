package com.paulsnow.finance.server.inboundmail;

/**
 * The boundary to one inbound email service. A real provider is a new adapter
 * and configuration only. Adapters are beans; the {@code sandbox} adapter
 * exists only when {@code finance.inbound-mail.sandbox.enabled} is true.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public interface InboundMailProvider {

    /** Returns the stable provider identifier used in webhook paths and records. */
    String id();

    /**
     * Checks a delivery's signature and timestamp against its raw body.
     *
     * @param delivery the delivery
     * @return whether it really came from this provider, recently
     */
    boolean verify(InboundDelivery delivery);

    /**
     * Parses a verified delivery's raw body.
     *
     * @param rawBody the raw body
     * @return the message
     * @throws IllegalArgumentException when the body cannot be understood
     */
    InboundMessage parse(byte[] rawBody);
}
