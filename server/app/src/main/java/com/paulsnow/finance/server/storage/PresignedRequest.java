package com.paulsnow.finance.server.storage;

import java.time.Instant;
import java.util.Map;

/**
 * A short-lived signed URL and the headers the client must send with it.
 *
 * @param url       signed URL
 * @param headers   headers included in the signature
 * @param expiresAt when the signature expires
 * @author Paul Snow
 * @since 0.0.0
 */
public record PresignedRequest(String url, Map<String, String> headers, Instant expiresAt) {
}
