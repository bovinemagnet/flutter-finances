package com.paulsnow.finance.server.inboundmail;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.common.ApiException;
import com.paulsnow.finance.server.jobs.JobService;
import com.paulsnow.finance.server.storage.ObjectStorage;
import com.paulsnow.finance.server.storage.Retention;

import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Takes a provider's delivery: bounds its size, verifies its signature, stores
 * the raw body and queues the work, so a slow scan cannot hold the webhook
 * open. Nothing in the body is read here, and a verified delivery gets the same
 * answer whatever it addresses, so the response reveals no address.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class InboundDeliveryReceiver {

    static final String JOB_TYPE = "inbound_mail.process";
    static final String RAW_PREFIX = "inbound-mail/raw/";

    private final List<InboundMailProvider> providers;
    private final InboundMailProperties properties;
    private final ObjectStorage storage;
    private final JobService jobs;

    InboundDeliveryReceiver(List<InboundMailProvider> providers, InboundMailProperties properties,
            ObjectStorage storage, JobService jobs) {
        this.providers = providers;
        this.properties = properties;
        this.storage = storage;
        this.jobs = jobs;
    }

    void receive(String providerId, String deliveryId, String timestamp, String signature, InputStream body) {
        byte[] bytes = bounded(body);
        InboundMailProvider provider = providers.stream().filter(p -> p.id().equals(providerId)).findFirst()
                .orElseThrow(InboundDeliveryReceiver::refused);
        if (!provider.verify(new InboundDelivery(deliveryId, timestamp, signature, bytes))) {
            throw refused();
        }
        String rawKey = RAW_PREFIX + UUID.randomUUID();
        store(rawKey, bytes);
        jobs.enqueue(JOB_TYPE, null,
                JsonNodeFactory.instance.objectNode().put("provider", providerId).put("rawKey", rawKey));
    }

    private byte[] bounded(InputStream body) {
        long limit = properties.maxDeliveryBytes();
        try {
            byte[] bytes = body.readNBytes(Math.toIntExact(limit + 1));
            if (bytes.length > limit) {
                throw new ApiException(HttpStatus.PAYLOAD_TOO_LARGE, "DELIVERY_TOO_LARGE",
                        "The delivery is too large.");
            }
            return bytes;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private void store(String key, byte[] bytes) {
        try {
            Path file = Files.createTempFile("inbound-delivery", ".bin");
            try {
                Files.write(file, bytes);
                storage.put(key, file, "application/octet-stream", Retention.STAGING);
            } finally {
                Files.deleteIfExists(file);
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static ApiException refused() {
        return new ApiException(HttpStatus.UNAUTHORIZED, "INVALID_SIGNATURE", "The delivery could not be verified.");
    }
}
