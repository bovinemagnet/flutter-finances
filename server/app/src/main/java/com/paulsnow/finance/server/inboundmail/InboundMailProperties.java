package com.paulsnow.finance.server.inboundmail;

import java.time.Duration;
import java.util.Map;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Inbound mail settings.
 *
 * @param tokenKey                 base64 AES key that encrypts address tokens; the feature is unavailable without it
 * @param domain                   domain of forwarding addresses; the feature is unavailable without it
 * @param webhookSecrets           provider identifier to webhook signing secret
 * @param webhookTolerance         how far a delivery's timestamp may be from now
 * @param maxDeliveryBytes         largest delivery accepted, before any parsing
 * @param maxAttachmentBytes       largest attachment kept (REC 05)
 * @param maxAttachmentsPerMessage attachments considered per message
 * @param maxMessagesPerDay        messages accepted per address in 24 hours
 * @param ignoreInlineBelowBytes   inline images smaller than this are ignored, as logos and signatures
 * @param retention                how long uncollected documents and message records are kept
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.inbound-mail")
public record InboundMailProperties(String tokenKey, String domain, Map<String, String> webhookSecrets,
        Duration webhookTolerance, Long maxDeliveryBytes, Long maxAttachmentBytes, Integer maxAttachmentsPerMessage,
        Integer maxMessagesPerDay, Long ignoreInlineBelowBytes, Duration retention) {

    public InboundMailProperties {
        webhookSecrets = webhookSecrets == null ? Map.of() : webhookSecrets;
        webhookTolerance = webhookTolerance == null ? Duration.ofMinutes(5) : webhookTolerance;
        maxDeliveryBytes = maxDeliveryBytes == null ? 67_108_864L : maxDeliveryBytes;
        maxAttachmentBytes = maxAttachmentBytes == null ? 20_971_520L : maxAttachmentBytes;
        maxAttachmentsPerMessage = maxAttachmentsPerMessage == null ? 10 : maxAttachmentsPerMessage;
        maxMessagesPerDay = maxMessagesPerDay == null ? 50 : maxMessagesPerDay;
        ignoreInlineBelowBytes = ignoreInlineBelowBytes == null ? 20_480L : ignoreInlineBelowBytes;
        retention = retention == null ? Duration.ofDays(30) : retention;
    }
}
