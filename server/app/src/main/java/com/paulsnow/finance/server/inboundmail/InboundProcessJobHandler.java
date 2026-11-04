package com.paulsnow.finance.server.inboundmail;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;

import org.springframework.context.ApplicationEventPublisher;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.common.AuditEvent;
import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;
import com.paulsnow.finance.server.jobs.PermanentJobFailure;
import com.paulsnow.finance.server.receipts.DocumentScanner;
import com.paulsnow.finance.server.storage.ObjectStorage;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Handles a stored delivery: finds the address, then keeps each attachment
 * that is identified from its bytes and passes the scan (SEC 04, REC 05), and
 * records why any other was refused. Every step can be repeated, so a retried
 * job does no work twice. Email content never reaches logs or audit details.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundProcessJobHandler implements JobHandler {

    private static final int MAX_SENDER = 320;
    private static final int MAX_SUBJECT = 200;
    private static final int MAX_FILE_NAME = 255;

    private final List<InboundMailProvider> providers;
    private final InboundAddressStore addresses;
    private final InboundMessageStore messages;
    private final InboundMailProperties properties;
    private final ObjectStorage storage;
    private final DocumentScanner scanner;
    private final ApplicationEventPublisher events;
    private final Clock clock;

    InboundProcessJobHandler(List<InboundMailProvider> providers, InboundAddressStore addresses,
            InboundMessageStore messages, InboundMailProperties properties, ObjectStorage storage,
            DocumentScanner scanner, ApplicationEventPublisher events, Clock clock) {
        this.providers = providers;
        this.addresses = addresses;
        this.messages = messages;
        this.properties = properties;
        this.storage = storage;
        this.scanner = scanner;
        this.events = events;
        this.clock = clock;
    }

    @Override
    public String type() {
        return InboundDeliveryReceiver.JOB_TYPE;
    }

    @Override
    public JsonNode handle(Job job) {
        String rawKey = job.payload().path("rawKey").asString();
        InboundMailProvider provider = providers.stream()
                .filter(p -> p.id().equals(job.payload().path("provider").asString())).findFirst()
                .orElseThrow(() -> new PermanentJobFailure("UNKNOWN_PROVIDER"));
        InboundMessage message;
        try {
            message = provider.parse(read(rawKey));
        } catch (IllegalArgumentException e) {
            storage.delete(rawKey);
            throw new PermanentJobFailure("MALFORMED_DELIVERY");
        }
        String outcome = addressOf(message.recipient())
                .map(address -> handle(provider.id(), address, message))
                .orElseGet(() -> {
                    events.publishEvent(AuditEvent.of(null, null, "inbound_mail.dropped", null, (UUID) null)
                            .withDetail("unknown_address"));
                    return "dropped";
                });
        storage.delete(rawKey);
        return JsonNodeFactory.instance.objectNode().put("outcome", outcome);
    }

    private Optional<InboundAddressStore.Address> addressOf(String recipient) {
        String[] parts = recipient.strip().toLowerCase(Locale.ROOT).split("@", -1);
        if (parts.length != 2 || !parts[1].equalsIgnoreCase(properties.domain())) {
            return Optional.empty();
        }
        return addresses.findActiveByToken(parts[0]);
    }

    private String handle(String provider, InboundAddressStore.Address address, InboundMessage message) {
        Instant now = clock.instant();
        InboundMessageStore.Handled handled = messages.insertOrFind(address, provider, message,
                bounded(message.sender(), MAX_SENDER), bounded(message.subject(), MAX_SUBJECT), now,
                now.plus(properties.retention()));
        if (!"processing".equals(handled.outcome())) {
            return handled.outcome();
        }
        String outcome;
        if (messages.countSince(address, now.minus(Duration.ofDays(1)), handled.id())
                >= properties.maxMessagesPerDay()) {
            outcome = "rate_limited";
        } else {
            attachments(address, handled.id(), message.attachments());
            outcome = outcomeOf(messages.documentStates(handled.id()));
        }
        messages.setOutcome(handled.id(), outcome);
        return outcome;
    }

    private void attachments(InboundAddressStore.Address address, UUID messageId,
            List<InboundMessage.Attachment> attachments) {
        int considered = 0;
        for (int index = 0; index < attachments.size(); index++) {
            InboundMessage.Attachment attachment = attachments.get(index);
            if (attachment.inline() && attachment.bytes().length < properties.ignoreInlineBelowBytes()) {
                continue;
            }
            considered++;
            if (messages.documentExists(messageId, index)) {
                continue;
            }
            // The identifier is derived, so a retry overwrites the same object.
            UUID documentId = UUID.nameUUIDFromBytes((messageId + "/" + index).getBytes(StandardCharsets.UTF_8));
            InboundMessageStore.NewDocument document = new InboundMessageStore.NewDocument(documentId, messageId, index,
                    fileName(attachment.fileName()));
            if (considered > properties.maxAttachmentsPerMessage()) {
                messages.insertRejected(document, "TOO_MANY");
            } else {
                keepOrRefuse(address, document, attachment.bytes());
            }
        }
    }

    private void keepOrRefuse(InboundAddressStore.Address address, InboundMessageStore.NewDocument document,
            byte[] bytes) {
        if (bytes.length > properties.maxAttachmentBytes()) {
            messages.insertRejected(document, "TOO_LARGE");
            return;
        }
        Optional<String> contentType = DocumentScanner.detectContentType(bytes);
        if (contentType.isEmpty()) {
            messages.insertRejected(document, "UNSUPPORTED_TYPE");
            return;
        }
        try {
            Path file = Files.createTempFile("inbound-attachment", ".bin");
            try {
                Files.write(file, bytes);
                DocumentScanner.Verdict verdict = scanner.scan(contentType.get(), file);
                if (!verdict.clean()) {
                    messages.insertRejected(document, verdict.reason());
                    return;
                }
                String key = "inbound-mail/" + address.workspaceId() + "/" + document.id();
                storage.put(key, file, contentType.get(), null);
                try {
                    messages.insertWaiting(document, key, contentType.get(), bytes.length, sha256(bytes));
                } catch (DataIntegrityViolationException e) {
                    // The member lost access meanwhile and the message went with it.
                    storage.delete(key);
                }
            } finally {
                Files.deleteIfExists(file);
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    static String outcomeOf(List<String> states) {
        if (states.isEmpty()) {
            return "no_attachment";
        }
        // A device can collect a document while later attachments are handled.
        return states.contains("waiting") || states.contains("collected") ? "documents" : "rejected";
    }

    private byte[] read(String key) {
        try (InputStream in = storage.read(key)) {
            return in.readAllBytes();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static String fileName(String claimed) {
        String[] parts = (claimed == null ? "" : claimed).split("[/\\\\]");
        String name = bounded(parts.length == 0 ? "" : parts[parts.length - 1], MAX_FILE_NAME).strip();
        return name.isEmpty() ? "attachment" : name;
    }

    private static String bounded(String text, int length) {
        String clean = (text == null ? "" : text).replaceAll("\\p{C}", "");
        return clean.length() <= length ? clean : clean.substring(0, length);
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is unavailable", e);
        }
    }
}
