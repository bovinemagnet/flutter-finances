package com.paulsnow.finance.server.bankfeeds;

import java.time.Duration;
import java.util.Map;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Bank feed settings ({@code finance.bank-feeds.*}). The sandbox provider
 * is switched on separately with {@code finance.bank-feeds.sandbox.enabled}.
 *
 * @param tokenKey              base64 AES key (128, 192 or 256 bits) that encrypts provider tokens at rest;
 *                              bank feeds are unavailable without it
 * @param webhookSecrets        HMAC-SHA256 secret per provider identifier
 * @param webhookTolerance      how far a webhook timestamp may be from the server clock
 * @param refreshBaseBackoff    delay after the first rate-limited refresh; doubles each time
 * @param refreshMaxBackoff     longest delay between rate-limited refreshes
 * @param maxRateLimitRetries   rate-limited refreshes retried automatically before waiting for the next trigger
 * @param staleAfter            age of the last successful refresh after which a feed is shown as stale
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.bank-feeds")
public record BankFeedProperties(String tokenKey, Map<String, String> webhookSecrets, Duration webhookTolerance,
        Duration refreshBaseBackoff, Duration refreshMaxBackoff, int maxRateLimitRetries, Duration staleAfter) {

    public BankFeedProperties {
        webhookSecrets = webhookSecrets == null ? Map.of() : Map.copyOf(webhookSecrets);
        webhookTolerance = webhookTolerance == null ? Duration.ofMinutes(5) : webhookTolerance;
        refreshBaseBackoff = refreshBaseBackoff == null ? Duration.ofMinutes(1) : refreshBaseBackoff;
        refreshMaxBackoff = refreshMaxBackoff == null ? Duration.ofHours(6) : refreshMaxBackoff;
        maxRateLimitRetries = maxRateLimitRetries <= 0 ? 8 : maxRateLimitRetries;
        staleAfter = staleAfter == null ? Duration.ofHours(36) : staleAfter;
    }

    /**
     * Returns the delay before retrying a rate-limited refresh: the base
     * delay doubled for each earlier consecutive limit, at least what the
     * provider asked for and at most the maximum.
     *
     * @param attempt    1 for the first consecutive limit
     * @param retryAfter the provider's requested delay
     * @return the delay
     */
    Duration backoff(int attempt, Duration retryAfter) {
        Duration exponential = refreshBaseBackoff.multipliedBy(1L << Math.min(Math.max(attempt, 1) - 1, 20));
        Duration delay = exponential.compareTo(retryAfter) >= 0 ? exponential : retryAfter;
        return delay.compareTo(refreshMaxBackoff) > 0 ? refreshMaxBackoff : delay;
    }
}
