package com.paulsnow.finance.server.storage;

import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;

import software.amazon.awssdk.services.s3.S3Client;

/**
 * Applies {@link StorageLifecycle} at start-up of the worker workload
 * ({@code finance.worker.enabled=true}), so the API never needs permission
 * to change bucket configuration. Set
 * {@code finance.storage.manage-lifecycle=false} when the bucket's
 * lifecycle is managed elsewhere (for example by infrastructure code); a
 * store that rejects the rules otherwise stops the worker from starting.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "finance.worker.enabled", havingValue = "true")
class StorageLifecycleConfiguration {

    @Bean
    @Order(Ordered.LOWEST_PRECEDENCE)
    @ConditionalOnProperty(name = "finance.storage.manage-lifecycle", havingValue = "true", matchIfMissing = true)
    ApplicationRunner applyStorageLifecycle(S3Client client, StorageProperties properties) {
        return args -> new StorageLifecycle(client, properties).apply();
    }
}
