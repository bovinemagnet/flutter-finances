package com.paulsnow.finance.server.inboundmail;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * A provider for development and tests. It takes JSON
 * ({@code {"messageId","to","from","subject","attachments":[{"fileName",
 * "contentBase64","inline"}]}}) signed with {@code v1=} and the hex
 * HMAC-SHA256 of {@code "<id>.<timestamp>.<raw body>"}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class SandboxInboundMailProvider implements InboundMailProvider {

    private final String secret;
    private final Duration tolerance;
    private final Clock clock;
    private final JsonMapper json;

    SandboxInboundMailProvider(String secret, Duration tolerance, Clock clock, JsonMapper json) {
        this.secret = secret;
        this.tolerance = tolerance;
        this.clock = clock;
        this.json = json;
    }

    @Override
    public String id() {
        return "sandbox";
    }

    @Override
    public boolean verify(InboundDelivery delivery) {
        if (secret == null || secret.isBlank() || delivery.id() == null || delivery.id().isBlank()
                || delivery.timestamp() == null || delivery.signature() == null) {
            return false;
        }
        Instant sent;
        try {
            sent = Instant.ofEpochSecond(Long.parseLong(delivery.timestamp().strip()));
        } catch (RuntimeException e) {
            return false;
        }
        if (Duration.between(sent, clock.instant()).abs().compareTo(tolerance) > 0) {
            return false;
        }
        return MessageDigest.isEqual(signature(delivery).getBytes(StandardCharsets.UTF_8),
                delivery.signature().strip().getBytes(StandardCharsets.UTF_8));
    }

    private String signature(InboundDelivery delivery) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            mac.update((delivery.id() + "." + delivery.timestamp().strip() + ".").getBytes(StandardCharsets.UTF_8));
            return "v1=" + HexFormat.of().formatHex(mac.doFinal(delivery.body()));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("HMAC-SHA256 is unavailable", e);
        }
    }

    @Override
    public InboundMessage parse(byte[] rawBody) {
        JsonNode node;
        try {
            node = json.readTree(rawBody);
        } catch (JacksonException e) {
            throw new IllegalArgumentException("Not JSON");
        }
        String messageId = node.path("messageId").asString("");
        String recipient = node.path("to").asString("");
        if (messageId.isBlank() || messageId.length() > 200 || recipient.isBlank()) {
            throw new IllegalArgumentException("A message needs an id and a recipient");
        }
        List<InboundMessage.Attachment> attachments = new ArrayList<>();
        for (JsonNode attachment : node.path("attachments")) {
            attachments.add(new InboundMessage.Attachment(attachment.path("fileName").asString(""),
                    Base64.getDecoder().decode(attachment.path("contentBase64").asString("")),
                    attachment.path("inline").asBoolean(false)));
        }
        return new InboundMessage(messageId, recipient, node.path("from").asString(""),
                node.path("subject").asString(""), attachments);
    }
}
