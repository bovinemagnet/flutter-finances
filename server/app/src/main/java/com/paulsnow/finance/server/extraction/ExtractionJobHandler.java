package com.paulsnow.finance.server.extraction;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Optional;
import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;
import com.paulsnow.finance.server.receipts.ReceiptService;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * Sends one released receipt document to the provider ({@code receipts.extract}).
 * Consent is checked again when the job runs and once more when the result
 * is stored. The job result carries identifiers and a status only, never
 * the recognised text.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ExtractionJobHandler implements JobHandler {

    private final ExtractionService extraction;
    private final ReceiptService receipts;

    ExtractionJobHandler(ExtractionService extraction, ReceiptService receipts) {
        this.extraction = extraction;
        this.receipts = receipts;
    }

    @Override
    public String type() {
        return ExtractionService.EXTRACT_JOB;
    }

    @Override
    public JsonNode handle(Job job) {
        UUID workspaceId = job.workspaceId();
        UUID receiptId = UUID.fromString(job.payload().path("receiptId").asString());
        UUID assetId = UUID.fromString(job.payload().path("assetId").asString());
        String contentType = job.payload().path("contentType").asString();
        ObjectNode result = JsonNodeFactory.instance.objectNode().put("receiptId", receiptId.toString())
                .put("assetId", assetId.toString());
        Optional<ExtractionProvider> provider = extraction.provider();
        if (provider.isEmpty() || !extraction.isGranted(workspaceId, provider.get().name())) {
            return result.put("status", "skipped");
        }
        byte[] document;
        try (InputStream in = receipts.openAvailable(workspaceId, assetId)) {
            document = in.readAllBytes();
        } catch (IllegalArgumentException e) {
            return result.put("status", "skipped");
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        ExtractedText text = provider.get().extract(contentType, document);
        boolean stored = extraction.store(workspaceId, receiptId, assetId, provider.get().name(),
                text == null ? new ExtractedText("", null) : text);
        return result.put("status", stored ? "extracted" : "skipped");
    }
}
