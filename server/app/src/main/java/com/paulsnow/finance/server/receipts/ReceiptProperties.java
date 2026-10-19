package com.paulsnow.finance.server.receipts;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Receipt document limits ({@code finance.receipts.*}), matching the
 * client's {@code ContentLimits} (REC 05).
 *
 * @param maxSizeBytes       largest accepted document (20 MiB)
 * @param maxPagesPerReceipt most pages a receipt's source documents may hold together (10)
 * @param maxImageSide       longest accepted image edge in pixels (16,384)
 * @param maxImagePixels     largest accepted image area in pixels (50 megapixels)
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.receipts")
public record ReceiptProperties(long maxSizeBytes, int maxPagesPerReceipt, int maxImageSide, long maxImagePixels) {

    public ReceiptProperties {
        maxSizeBytes = maxSizeBytes <= 0 ? 20L * 1024 * 1024 : maxSizeBytes;
        maxPagesPerReceipt = maxPagesPerReceipt <= 0 ? 10 : maxPagesPerReceipt;
        maxImageSide = maxImageSide <= 0 ? 16_384 : maxImageSide;
        maxImagePixels = maxImagePixels <= 0 ? 50_000_000L : maxImagePixels;
    }
}
