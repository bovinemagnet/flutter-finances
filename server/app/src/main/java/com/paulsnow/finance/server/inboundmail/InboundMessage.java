package com.paulsnow.finance.server.inboundmail;

import java.util.List;

/**
 * A parsed email. Everything in it comes from an outside sender and is
 * untrusted; a declared content type is deliberately not part of it.
 *
 * @param messageId   the provider's stable message identifier
 * @param recipient   the address it was sent to
 * @param sender      the claimed sender
 * @param subject     the subject
 * @param attachments the attachments, in order
 *
 * @author Paul Snow
 * @since 0.0.0
 */
public record InboundMessage(String messageId, String recipient, String sender, String subject,
        List<Attachment> attachments) {

    /**
     * One attachment.
     *
     * @param fileName the claimed file name
     * @param bytes    the content
     * @param inline   whether it is embedded in the message rather than attached
     */
    public record Attachment(String fileName, byte[] bytes, boolean inline) {
    }
}
