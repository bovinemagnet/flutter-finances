package com.paulsnow.finance.server.receipts;

import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Provides the default {@link DocumentScanner} unless the deployment
 * declares its own.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
class ReceiptsConfiguration {

    @Bean
    @ConditionalOnMissingBean(DocumentScanner.class)
    DocumentScanner structuralDocumentScanner(ReceiptProperties properties) {
        return new StructuralDocumentScanner(properties.maxImageDimension());
    }
}
