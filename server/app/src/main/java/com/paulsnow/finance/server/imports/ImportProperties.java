package com.paulsnow.finance.server.imports;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Import settings ({@code finance.imports.*}).
 *
 * @param maxRows             largest accepted statement, in records
 * @param synchronousRowLimit rows committed within the request; larger batches commit as a job
 * @param previewRows         rows returned with a preview or batch page by default
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.imports")
public record ImportProperties(int maxRows, int synchronousRowLimit, int previewRows) {

    public ImportProperties {
        maxRows = maxRows <= 0 ? 50_000 : maxRows;
        synchronousRowLimit = synchronousRowLimit <= 0 ? 1000 : synchronousRowLimit;
        previewRows = previewRows <= 0 ? 500 : previewRows;
    }
}
