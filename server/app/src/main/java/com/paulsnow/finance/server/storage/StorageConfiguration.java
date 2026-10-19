package com.paulsnow.finance.server.storage;

import java.net.URI;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.checksums.RequestChecksumCalculation;
import software.amazon.awssdk.core.checksums.ResponseChecksumValidation;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;
import software.amazon.awssdk.services.s3.model.HeadBucketRequest;
import software.amazon.awssdk.services.s3.model.NoSuchBucketException;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;

/**
 * Builds the S3 client and presigner from {@link StorageProperties}.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
@Configuration(proxyBeanMethods = false)
class StorageConfiguration {

    private static final Logger LOG = LoggerFactory.getLogger(StorageConfiguration.class);

    @Bean(destroyMethod = "close")
    S3Client s3Client(StorageProperties properties) {
        var builder = S3Client.builder()
                .region(Region.of(properties.region()))
                .credentialsProvider(credentials(properties))
                .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED)
                .responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
                .serviceConfiguration(S3Configuration.builder()
                        .pathStyleAccessEnabled(properties.pathStyleAccess()).build());
        String endpoint = StorageProperties.blankToNull(properties.endpoint());
        if (endpoint != null) {
            builder.endpointOverride(URI.create(endpoint));
        }
        return builder.build();
    }

    @Bean(destroyMethod = "close")
    S3Presigner s3Presigner(StorageProperties properties) {
        var builder = S3Presigner.builder()
                .region(Region.of(properties.region()))
                .credentialsProvider(credentials(properties))
                .serviceConfiguration(S3Configuration.builder()
                        .pathStyleAccessEnabled(properties.pathStyleAccess()).build());
        String endpoint = StorageProperties.blankToNull(properties.presignEndpoint());
        if (endpoint == null) {
            endpoint = StorageProperties.blankToNull(properties.endpoint());
        }
        if (endpoint != null) {
            builder.endpointOverride(URI.create(endpoint));
        }
        return builder.build();
    }

    @Bean
    ObjectStorage objectStorage(S3Client client, S3Presigner presigner, StorageProperties properties) {
        return new S3ObjectStorage(client, presigner, properties);
    }

    /**
     * Creates the bucket at startup when {@code finance.storage.create-bucket}
     * is true, before any other runner (such as the lifecycle rules) uses it.
     */
    @Bean
    @Order(Ordered.HIGHEST_PRECEDENCE)
    ApplicationRunner createBucket(S3Client client, StorageProperties properties) {
        return args -> {
            if (!properties.createBucket()) {
                return;
            }
            try {
                client.headBucket(HeadBucketRequest.builder().bucket(properties.bucket()).build());
            } catch (S3Exception e) {
                // HEAD has no error body, so a missing bucket is a bare 404.
                if (!(e instanceof NoSuchBucketException) && e.statusCode() != 404) {
                    throw e;
                }
                try {
                    client.createBucket(CreateBucketRequest.builder().bucket(properties.bucket()).build());
                    LOG.info("Created object storage bucket {}", properties.bucket());
                } catch (BucketAlreadyOwnedByYouException ignored) {
                    // Another instance created it first.
                }
            }
        };
    }

    private static AwsCredentialsProvider credentials(StorageProperties properties) {
        String accessKey = StorageProperties.blankToNull(properties.accessKey());
        if (accessKey == null) {
            return DefaultCredentialsProvider.builder().build();
        }
        return StaticCredentialsProvider.create(AwsBasicCredentials.create(accessKey, properties.secretKey()));
    }
}
