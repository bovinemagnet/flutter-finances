package com.paulsnow.finance.server.support;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.test.context.DynamicPropertyRegistrar;
import org.testcontainers.containers.MinIOContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * PostgreSQL and S3-compatible object storage for integration tests. The
 * containers are started once per JVM and shared by every test context.
 * <p>
 * The upstream {@code minio/minio} image is no longer published, so a
 * rebuild of the same server ({@code pgsty/minio}) is used as a compatible
 * substitute; override with {@code -Dfinance.test.minio-image=...}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfiguration {

    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer(
            DockerImageName.parse(System.getProperty("finance.test.postgres-image", "postgres:18"))
                    .asCompatibleSubstituteFor("postgres"));

    static final MinIOContainer MINIO = new MinIOContainer(
            DockerImageName.parse(System.getProperty("finance.test.minio-image",
                    "pgsty/minio:RELEASE.2026-08-04T00-00-00Z")).asCompatibleSubstituteFor("minio/minio"));

    static {
        POSTGRES.start();
        MINIO.start();
    }

    @Bean
    @ServiceConnection
    PostgreSQLContainer postgres() {
        return POSTGRES;
    }

    @Bean
    DynamicPropertyRegistrar objectStorageProperties() {
        return registry -> {
            registry.add("finance.storage.endpoint", MINIO::getS3URL);
            registry.add("finance.storage.access-key", MINIO::getUserName);
            registry.add("finance.storage.secret-key", MINIO::getPassword);
            registry.add("finance.storage.bucket", () -> "finance-test");
            registry.add("finance.storage.create-bucket", () -> "true");
        };
    }

    /** Returns the S3 endpoint, for direct anonymous access checks. */
    public static String objectStorageEndpoint() {
        return MINIO.getS3URL();
    }
}
