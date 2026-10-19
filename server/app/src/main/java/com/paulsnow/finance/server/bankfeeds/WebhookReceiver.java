package com.paulsnow.finance.server.bankfeeds;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import com.paulsnow.finance.server.bankfeeds.ConnectionStore.Connection;
import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.common.AuditEvent;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * Verifies and handles provider webhooks (BANK 03). A delivery is accepted
 * only with a valid {@code X-Webhook-Signature} ({@code v1=} and the hex
 * HMAC-SHA256 of {@code "<X-Webhook-Id>.<X-Webhook-Timestamp>.<raw body>"}
 * under the provider's configured secret) and a timestamp within the
 * configured tolerance; each delivery id is handled once. A webhook only
 * ever triggers a refresh or ends collection; it never carries
 * transactions the server trusts.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class WebhookReceiver {

    private final BankFeedService service;
    private final ConnectionStore store;
    private final BankFeedProperties properties;
    private final JdbcClient jdbc;
    private final JsonMapper json;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    WebhookReceiver(BankFeedService service, ConnectionStore store, BankFeedProperties properties, JdbcClient jdbc,
            JsonMapper json, Clock clock, ApplicationEventPublisher events) {
        this.service = service;
        this.store = store;
        this.properties = properties;
        this.jdbc = jdbc;
        this.json = json;
        this.clock = clock;
        this.events = events;
    }

    /**
     * Handles one delivery.
     *
     * @return {@code accepted}, or {@code duplicate} for a delivery already handled
     */
    @Transactional
    String receive(String provider, String deliveryId, String timestamp, String signature, byte[] body) {
        String secret = properties.webhookSecrets().get(provider);
        if (secret == null || secret.isBlank() || !service.hasProvider(provider)) {
            throw ApiException.notFound("NOT_FOUND", "Not found.");
        }
        if (deliveryId == null || deliveryId.isBlank() || deliveryId.length() > 200 || timestamp == null
                || !verify(secret, deliveryId, timestamp, signature, body)) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "INVALID_SIGNATURE", "The webhook signature is invalid.");
        }
        Instant sent;
        try {
            sent = Instant.ofEpochSecond(Long.parseLong(timestamp.strip()));
        } catch (RuntimeException e) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "TIMESTAMP_OUT_OF_TOLERANCE",
                    "The webhook timestamp is invalid.");
        }
        Instant now = clock.instant();
        if (Duration.between(sent, now).abs().compareTo(properties.webhookTolerance()) > 0) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "TIMESTAMP_OUT_OF_TOLERANCE",
                    "The webhook timestamp is outside the allowed window.");
        }
        int fresh = jdbc.sql("insert into bank_feed_webhook_delivery (provider, delivery_id, received_at) "
                        + "values (?, ?, ?) on conflict do nothing")
                .params(provider, deliveryId, Timestamp.from(now)).update();
        if (fresh == 0) {
            return "duplicate";
        }
        JsonNode event;
        try {
            event = json.readTree(body);
        } catch (JacksonException e) {
            return "accepted";
        }
        Optional<Connection> connection = store.findByReference(provider,
                event.path("connectionReference").asString());
        if (connection.isEmpty() || !connection.get().collecting()) {
            return "accepted";
        }
        Connection c = connection.get();
        switch (event.path("type").asString()) {
            case "transactions.updated" -> service.enqueueRefresh(c.workspaceId(), c.id());
            case "consent.revoked" -> {
                store.revoke(c.id());
                events.publishEvent(AuditEvent.of(c.workspaceId(), null, "bank_feed.revoked_by_provider",
                        "bank_feed", c.id()));
            }
            case "consent.expired" -> store.expire(c.id(), null);
            default -> {
                // Unknown event types are acknowledged and ignored.
            }
        }
        return "accepted";
    }

    /** Removes delivery records old enough that their timestamps would be rejected anyway. */
    int purgeDeliveries() {
        Duration keep = properties.webhookTolerance().multipliedBy(2).compareTo(Duration.ofDays(1)) > 0
                ? properties.webhookTolerance().multipliedBy(2) : Duration.ofDays(1);
        return jdbc.sql("delete from bank_feed_webhook_delivery where received_at < ?")
                .param(Timestamp.from(clock.instant().minus(keep))).update();
    }

    private static boolean verify(String secret, String deliveryId, String timestamp, String signature,
            byte[] body) {
        if (signature == null || !signature.startsWith("v1=")) {
            return false;
        }
        byte[] provided;
        try {
            provided = HexFormat.of().parseHex(signature.substring(3).strip().toLowerCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            return false;
        }
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            mac.update((deliveryId + "." + timestamp + ".").getBytes(StandardCharsets.UTF_8));
            return MessageDigest.isEqual(mac.doFinal(body == null ? new byte[0] : body), provided);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }
}
