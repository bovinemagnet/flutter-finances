package com.paulsnow.finance.server.inboundmail;

/**
 * One delivery as a provider posted it, before anything in it is trusted.
 *
 * @param id        the provider's delivery identifier
 * @param timestamp when the provider signed it, in epoch seconds
 * @param signature the provider's signature
 * @param body      the raw request body
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public record InboundDelivery(String id, String timestamp, String signature, byte[] body) {
}
