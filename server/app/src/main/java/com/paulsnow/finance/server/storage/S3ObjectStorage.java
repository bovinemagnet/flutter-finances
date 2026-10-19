package com.paulsnow.finance.server.storage;

import java.io.InputStream;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.Delete;
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest;
import software.amazon.awssdk.services.s3.model.DeleteObjectsRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;
import software.amazon.awssdk.services.s3.model.HeadObjectResponse;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Response;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.ObjectIdentifier;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.model.S3Object;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;
import software.amazon.awssdk.services.s3.presigner.model.PresignedGetObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PresignedPutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;

/**
 * {@link ObjectStorage} on AWS SDK v2, for S3 or any S3-compatible store.
 *
 * @author Paul Snow
 * @since 0.0.0
 */
class S3ObjectStorage implements ObjectStorage {

    private final S3Client client;
    private final S3Presigner presigner;
    private final StorageProperties properties;

    S3ObjectStorage(S3Client client, S3Presigner presigner, StorageProperties properties) {
        this.client = client;
        this.presigner = presigner;
        this.properties = properties;
    }

    @Override
    public PresignedRequest presignPut(String key, String contentType, Retention retention) {
        PresignedPutObjectRequest signed = presigner.presignPutObject(PutObjectPresignRequest.builder()
                .signatureDuration(properties.uploadUrlTtl())
                .putObjectRequest(PutObjectRequest.builder().bucket(properties.bucket()).key(key)
                        .contentType(contentType).tagging(retention == null ? null : retention.tagging()).build())
                .build());
        return new PresignedRequest(signed.url().toString(), clientHeaders(signed.signedHeaders()),
                signed.expiration());
    }

    @Override
    public PresignedRequest presignGet(String key) {
        PresignedGetObjectRequest signed = presigner.presignGetObject(GetObjectPresignRequest.builder()
                .signatureDuration(properties.downloadUrlTtl())
                .getObjectRequest(GetObjectRequest.builder().bucket(properties.bucket()).key(key).build())
                .build());
        return new PresignedRequest(signed.url().toString(), clientHeaders(signed.signedHeaders()),
                signed.expiration());
    }

    @Override
    public Optional<ObjectInfo> head(String key) {
        try {
            HeadObjectResponse response = client.headObject(HeadObjectRequest.builder()
                    .bucket(properties.bucket()).key(key).build());
            return Optional.of(new ObjectInfo(response.contentLength(), response.contentType()));
        } catch (NoSuchKeyException e) {
            return Optional.empty();
        } catch (S3Exception e) {
            if (e.statusCode() == 404) {
                return Optional.empty();
            }
            throw e;
        }
    }

    @Override
    public InputStream read(String key) {
        return client.getObject(GetObjectRequest.builder().bucket(properties.bucket()).key(key).build());
    }

    @Override
    public void put(String key, Path file, String contentType, Retention retention) {
        client.putObject(PutObjectRequest.builder().bucket(properties.bucket()).key(key).contentType(contentType)
                .tagging(retention == null ? null : retention.tagging()).build(), RequestBody.fromFile(file));
    }

    @Override
    public void delete(String key) {
        client.deleteObject(DeleteObjectRequest.builder().bucket(properties.bucket()).key(key).build());
    }

    @Override
    public int deletePrefix(String prefix) {
        if (prefix == null || !prefix.endsWith("/") || prefix.length() < 2) {
            throw new IllegalArgumentException("Prefix must be a non-empty folder");
        }
        int deleted = 0;
        String token = null;
        do {
            ListObjectsV2Response page = client.listObjectsV2(ListObjectsV2Request.builder()
                    .bucket(properties.bucket()).prefix(prefix).continuationToken(token).build());
            List<ObjectIdentifier> keys = new ArrayList<>();
            for (S3Object object : page.contents()) {
                keys.add(ObjectIdentifier.builder().key(object.key()).build());
            }
            if (!keys.isEmpty()) {
                client.deleteObjects(DeleteObjectsRequest.builder().bucket(properties.bucket())
                        .delete(Delete.builder().objects(keys).quiet(true).build()).build());
                deleted += keys.size();
            }
            token = Boolean.TRUE.equals(page.isTruncated()) ? page.nextContinuationToken() : null;
        } while (token != null);
        return deleted;
    }

    private static Map<String, String> clientHeaders(Map<String, List<String>> signed) {
        Map<String, String> headers = new LinkedHashMap<>();
        signed.forEach((name, values) -> {
            if (!"host".equalsIgnoreCase(name)) {
                headers.put(name, String.join(",", values));
            }
        });
        return headers;
    }
}
