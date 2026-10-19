package com.paulsnow.finance.server.storage;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Object storage settings ({@code finance.storage.*}).
 *
 * @param endpoint          S3 endpoint override, empty for AWS
 * @param presignEndpoint   endpoint clients reach for presigned URLs, empty to use {@code endpoint}
 * @param region            signing region
 * @param bucket            private bucket holding every workspace's objects
 * @param accessKey         static access key, empty for the default credential chain
 * @param secretKey         static secret key
 * @param pathStyleAccess   path-style addressing (MinIO)
 * @param createBucket      create the bucket at startup (development and tests)
 * @param uploadUrlTtl      lifetime of presigned upload URLs
 * @param downloadUrlTtl    lifetime of presigned download URLs
 * @author Paul Snow
 * @since 0.0.0
 */
@ConfigurationProperties("finance.storage")
public record StorageProperties(String endpoint, String presignEndpoint, String region, String bucket,
        String accessKey, String secretKey, boolean pathStyleAccess, boolean createBucket, Duration uploadUrlTtl,
        Duration downloadUrlTtl) {

    public StorageProperties {
        region = blankToNull(region) == null ? "ap-southeast-2" : region;
        uploadUrlTtl = uploadUrlTtl == null ? Duration.ofMinutes(15) : uploadUrlTtl;
        downloadUrlTtl = downloadUrlTtl == null ? Duration.ofMinutes(5) : downloadUrlTtl;
    }

    static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
