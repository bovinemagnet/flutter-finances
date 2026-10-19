package com.paulsnow.finance.server.receipts;

import java.util.UUID;

import org.springframework.stereotype.Component;

import com.paulsnow.finance.server.jobs.Job;
import com.paulsnow.finance.server.jobs.JobHandler;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.JsonNodeFactory;

/**
 * Background scan of a quarantined document (SEC 04). Idempotent: an asset
 * that is no longer quarantined is left as it is.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Component
class ScanJobHandler implements JobHandler {

    private final ReceiptService receipts;
    private final DocumentScanner scanner;

    ScanJobHandler(ReceiptService receipts, DocumentScanner scanner) {
        this.receipts = receipts;
        this.scanner = scanner;
    }

    @Override
    public String type() {
        return ReceiptService.SCAN_JOB;
    }

    @Override
    public JsonNode handle(Job job) {
        UUID assetId = UUID.fromString(job.payload().path("assetId").asString());
        String status = receipts.scan(assetId, scanner);
        return JsonNodeFactory.instance.objectNode().put("assetId", assetId.toString()).put("status", status);
    }
}
