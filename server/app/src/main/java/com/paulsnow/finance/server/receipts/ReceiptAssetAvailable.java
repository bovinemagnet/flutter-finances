package com.paulsnow.finance.server.receipts;

import java.util.UUID;

/**
 * Published when the scan releases a quarantined document, so modules that
 * process documents (for example optional cloud extraction) can queue their
 * own work. Identifiers and types only; never document content.
 *
 * @param workspaceId owning workspace
 * @param receiptId   receipt
 * @param assetId     the released asset
 * @param kind        {@code source} or {@code derivative}
 * @param contentType confirmed content type
 * @author Paul Snow
 * @since 0.0.0
 */
public record ReceiptAssetAvailable(UUID workspaceId, UUID receiptId, UUID assetId, String kind,
        String contentType) {
}
