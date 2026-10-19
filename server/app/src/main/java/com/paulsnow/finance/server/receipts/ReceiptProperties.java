package com.paulsnow.finance.server.receipts;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Receipt document limits ({@code finance.receipts.*}).
 *
 * @param maxSizeBytes      largest accepted document
 * @param maxImageDimension largest accepted image width or height in pixels
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.receipts")
public record ReceiptProperties(long maxSizeBytes, int maxImageDimension) {

    public ReceiptProperties {
        maxSizeBytes = maxSizeBytes <= 0 ? 25L * 1024 * 1024 : maxSizeBytes;
        maxImageDimension = maxImageDimension <= 0 ? 20_000 : maxImageDimension;
    }
}
